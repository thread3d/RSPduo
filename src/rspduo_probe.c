/*
 * rspduo_probe.c - standalone receive checker for an SDRplay RSPduo
 *
 * Deliberately independent of ogn-rf: it uses the SDRplay API directly, so it answers the
 * questions "is the device working at all" and "is my conversion scale right" without any of
 * ogn-rf's machinery in the way.
 *
 * It does four things:
 *
 *   1. Reports the API version, and every RSP device the service can see, with model and serial.
 *   2. Opens tuner A, tunes it, and captures a fixed number of samples.
 *   3. Reports the statistics that settle the 8-bit conversion scale: the raw int16 range and
 *      the count of samples that would rail after the shift. If the raw range is about +-30000,
 *      a shift of 8 is right. If it is about +-2000, the samples are not left-justified the way
 *      the backend assumes and the shift belongs at 4.
 *   4. Optionally writes the converted interleaved u8 I/Q to a file, which tools/spectrum.py
 *      turns into a periodogram - the fastest way to see whether anything is on the air.
 *
 * Build:
 *     gcc -O2 -Wall -o rspduo_probe rspduo_probe.c -lsdrplay_api -lpthread -lm
 *
 * Usage:
 *     ./rspduo_probe [-f freq_hz] [-r rate_hz] [-g gain_dB] [-l lna_state] [-n samples] [-o out.u8]
 *
 * The vendor EULA permits use of the API; see the licence text the installer leaves in $HOME.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>

#include <sdrplay_api.h>

static volatile int Stop = 0;

static void on_signal(int sig) { (void)sig; Stop = 1; }

/* ------------------------------------------------------------------------------------------- */
/* Capture state shared with the API's stream thread                                           */
/* ------------------------------------------------------------------------------------------- */

typedef struct
{
  pthread_mutex_t Lock;
  pthread_cond_t  Cond;

  short  *RawI;            /* raw int16 as the API delivered them, kept for the range report */
  short  *RawQ;
  size_t  RawCap;          /* samples */
  size_t  RawCount;        /* samples stored so far */

  uint8_t *Out;            /* converted interleaved u8, only filled if wanted */
  size_t   OutCap;
  size_t   OutCount;

  int      Shift;          /* >>Shift then +128 */
  double   TFirst;         /* wall clock at the first callback */
  double   TLast;          /* wall clock at each callback */
  size_t   NTimed;         /* samples covered by TFirst..TLast */
  long     ClippedLow;     /* samples that railed at 0 */
  long     ClippedHigh;    /* samples that railed at 255 */
} Capture;

/* Both tuners use the same callback body; which Capture it fills is what differs. The API's
   stream callbacks carry no user tuner tag of their own, so there is one wrapper per tuner. */
static double now_sec(void);

static void capture_push(Capture *C, short *xi, short *xq, unsigned int numSamples)
{ if (C == NULL || numSamples == 0) return;

  pthread_mutex_lock(&C->Lock);
  if (C->RawCount == 0) C->TFirst = now_sec();
  C->TLast = now_sec();
  C->NTimed = C->RawCount + numSamples;

  for (unsigned int i = 0; i < numSamples; i++)
  { if (C->RawCount < C->RawCap)
    { C->RawI[C->RawCount] = xi[i];
      C->RawQ[C->RawCount] = xq[i];
      C->RawCount++; }
    if (C->Out && C->OutCount + 2 <= C->OutCap)
    { int vi = (xi[i] >> C->Shift) + 128; if (vi < 0) { vi = 0; C->ClippedLow++; } else if (vi > 255) { vi = 255; C->ClippedHigh++; }
      int vq = (xq[i] >> C->Shift) + 128; if (vq < 0) { vq = 0; C->ClippedLow++; } else if (vq > 255) { vq = 255; C->ClippedHigh++; }
      C->Out[C->OutCount++] = (uint8_t)vi;
      C->Out[C->OutCount++] = (uint8_t)vq; } }

  pthread_cond_signal(&C->Cond);
  pthread_mutex_unlock(&C->Lock); }

/* Filled by main once the tuner B Capture exists, so the free function below can reach it
   without the callback signature changing. */
static Capture *CaptureBPtr = NULL;

static double now_sec(void)
{ struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + 1e-9 * ts.tv_nsec; }

static void stream_a_cb(short *xi, short *xq, sdrplay_api_StreamCbParamsT *params,
                        unsigned int numSamples, unsigned int reset, void *cbContext)
{ (void)params; (void)reset;
  capture_push((Capture *)cbContext, xi, xq, numSamples); }

static void stream_b_cb(short *xi, short *xq, sdrplay_api_StreamCbParamsT *params,
                        unsigned int numSamples, unsigned int reset, void *cbContext)
{ (void)params; (void)reset; (void)cbContext;
  capture_push(CaptureBPtr, xi, xq, numSamples); }

static void event_cb(sdrplay_api_EventT eventId, sdrplay_api_TunerSelectT tuner,
                     sdrplay_api_EventParamsT *params, void *cbContext)
{ (void)tuner; (void)cbContext;
  switch (eventId)
  { case sdrplay_api_GainChange:
      if (params) printf("  [event] gain change: %5.1f dB (gRdB %u, LNA %u)\n",
                         params->gainParams.currGain, params->gainParams.gRdB, params->gainParams.lnaGRdB);
      break;
    case sdrplay_api_PowerOverloadChange:
      printf("  [event] ADC overload %s\n",
             (params && params->powerOverloadParams.powerOverloadChangeType == sdrplay_api_Overload_Detected)
             ? "DETECTED - reduce gain" : "corrected");
      break;
    case sdrplay_api_DeviceRemoved:
      printf("  [event] device removed\n"); Stop = 1; break;
    case sdrplay_api_DeviceFailure:
      printf("  [event] device failure\n"); Stop = 1; break;
    default: break; }
}

static const char *model_name(unsigned char hwVer)
{ switch (hwVer)
  { case SDRPLAY_RSP1_ID:    return "RSP1";
    case SDRPLAY_RSP1A_ID:   return "RSP1A";
    case SDRPLAY_RSP2_ID:    return "RSP2";
    case SDRPLAY_RSPduo_ID:  return "RSPduo";
    case SDRPLAY_RSPdx_ID:   return "RSPdx";
    case SDRPLAY_RSP1B_ID:   return "RSP1B";
    case SDRPLAY_RSPdxR2_ID: return "RSPdxR2";
    default:                 return "RSP-unknown"; } }

/* ------------------------------------------------------------------------------------------- */

int main(int argc, char **argv)
{ double  FreqHz    = 868300000.0;
  double  RateHz    = 2000000.0;
  int     GainRedDB = 40;
  int     LnaState  = 0;
  size_t  Requested = 2000000;      /* samples, 1 s at 2 MSps */
  const char *OutPath = NULL;
  int     Shift     = 8;
  int     BulkMode  = 1;
  int     DualMode  = 0;          /* -D: drive both tuners simultaneously */
  int     Deci      = 1;          /* -d: decimation factor (2,4,8,16,32; powers of two only) */
  int     BiasTee   = 0;          /* -t: enable the 4.7 V bias tee (Tuner 2 port only) */
  double  FreqB     = 0.0;        /* -B: tuner B centre, default FreqHz + 100 kHz */

  int opt;
  while ((opt = getopt(argc, argv, "f:r:g:l:n:o:s:m:B:d:Dth")) != -1)
  { switch (opt)
    { case 'f': FreqHz    = atof(optarg); break;
      case 'r': RateHz    = atof(optarg); break;
      case 'g': GainRedDB = atoi(optarg); break;
      case 'l': LnaState  = atoi(optarg); break;
      case 'n': Requested = (size_t)strtoull(optarg, NULL, 0); break;
      case 'o': OutPath   = optarg; break;
      case 's': Shift     = atoi(optarg); break;
      case 'm': BulkMode  = (strcmp(optarg, "isoch") != 0); break;
      case 'B': FreqB     = atof(optarg); break;
      case 'd': Deci      = atoi(optarg); break;
      case 'D': DualMode  = 1; break;
      case 't': BiasTee   = 1; break;
      default:
        printf("usage: %s [-f freq_hz] [-r rate_hz] [-g if_gain_reduction_dB] [-l lna_state]\n"
               "          [-n samples] [-o out.u8] [-s shift]\n", argv[0]);
        printf("  -f  centre frequency, default 868300000\n");
        printf("  -r  sample rate,       default 2000000 (RSPduo: 2, 6 or 8 MHz)\n");
        printf("  -g  IF gain reduction, default 40 dB (20..59)\n");
        printf("  -l  LNA state,         default 0 (0 = most gain)\n");
        printf("  -n  samples to capture,default 2000000\n");
        printf("  -o  write converted u8 I/Q here (feed to tools/spectrum.py)\n");
        printf("  -s  conversion shift,  default 8\n");
    printf("  -m  transfer mode: bulk (default) or isoch\n");
    printf("  -d  decimation factor: 2, 4, 8, 16 or 32 (default 1 = off)\n");
    printf("  -D  dual-tuner mode: both tuners stream at once\n");
    printf("  -t  enable the bias tee (4.7 V, Tuner 2 port only)\n");
    printf("  -B  tuner B centre frequency, default -f + 100 kHz\n");
        return 2; } }

  signal(SIGINT, on_signal); signal(SIGTERM, on_signal);

  printf("SDRplay API probe\n=================\n");

  sdrplay_api_ErrT err = sdrplay_api_Open();
  if (err != sdrplay_api_Success)
  { printf("sdrplay_api_Open() failed: %s\n", sdrplay_api_GetErrorString(err));
    if (err == sdrplay_api_ServiceNotResponding)
      printf("  -> the API service is not running: sudo systemctl start sdrplay\n");
    return 1; }

  float ver = 0;
  if (sdrplay_api_ApiVersion(&ver) != sdrplay_api_Success)
  { printf("sdrplay_api_ApiVersion() failed\n"); sdrplay_api_Close(); return 1; }
  printf("API version : %4.2f (headers %4.2f)%s\n", ver, SDRPLAY_API_VERSION,
         fabsf(ver - SDRPLAY_API_VERSION) > 0.001f ? "  MISMATCH" : "");

  err = sdrplay_api_LockDeviceApi();
  if (err != sdrplay_api_Success)
  { printf("LockDeviceApi() failed: %s\n", sdrplay_api_GetErrorString(err)); sdrplay_api_Close(); return 1; }

  sdrplay_api_DeviceT devices[SDRPLAY_MAX_DEVICES];
  unsigned int ndev = 0;
  err = sdrplay_api_GetDevices(devices, &ndev, SDRPLAY_MAX_DEVICES);
  sdrplay_api_UnlockDeviceApi();
  if (err != sdrplay_api_Success)
  { printf("GetDevices() failed: %s\n", sdrplay_api_GetErrorString(err)); sdrplay_api_Close(); return 1; }

  printf("devices     : %u\n", ndev);
  for (unsigned int i = 0; i < ndev; i++)
    printf("  #%u %-10s S/N %s\n", i, model_name(devices[i].hwVer), devices[i].SerNo);

  if (ndev == 0)
  { printf("  -> no device visible. Check lsusb for 1df7:3020, and re-plug it so udev re-applies.\n");
    sdrplay_api_Close(); return 1; }

  sdrplay_api_DeviceT dev = devices[0];
  /* In dual mode the API demands Tuner_Both, Dual_Tuner mode, and rspDuoSampleFreq set before
     the device is selected; a valid (rate, bandwidth, IF, decimation) combination is also
     required, and IF_Zero is not among them. */
  /* Dual-tuner mode accepts only fixed (ADC rate, bandwidth, IF, decimation) combinations.
     Pick one from the ADC rate requested with -r. These come from the reference
     dual-tuner-recorder implementation; anything else makes Init() fail. */
  sdrplay_api_Bw_MHzT DualBw = sdrplay_api_BW_0_600;
  sdrplay_api_If_kHzT DualIf = sdrplay_api_IF_0_450;
  int                 DualDec = 2;
  double              DualFs  = 2000000.0;
  if (DualMode)
  { if      (RateHz >= 8.0e6) { DualFs = 8000000.0; DualBw = sdrplay_api_BW_1_536; DualIf = sdrplay_api_IF_2_048; DualDec = 4; }
    else if (RateHz >= 6.0e6) { DualFs = 6000000.0; DualBw = sdrplay_api_BW_1_536; DualIf = sdrplay_api_IF_1_620; DualDec = 3; }
    else if (RateHz >= 3.0e6) { DualFs = 2000000.0; DualBw = sdrplay_api_BW_0_600; DualIf = sdrplay_api_IF_0_450; DualDec = 2; }
    else if (RateHz >  1.2e6) { DualFs = 2000000.0; DualBw = sdrplay_api_BW_0_600; DualIf = sdrplay_api_IF_0_450; DualDec = 2; }
    else                      { DualFs = 2000000.0; DualBw = sdrplay_api_BW_0_300; DualIf = sdrplay_api_IF_0_450; DualDec = 4; } }
  if (DualMode)
  { if (FreqB == 0.0) FreqB = FreqHz + 100e3;
    dev.tuner          = sdrplay_api_Tuner_Both;
    dev.rspDuoMode     = sdrplay_api_RspDuoMode_Dual_Tuner;
    dev.rspDuoSampleFreq = DualFs; }
  else
  { dev.tuner          = sdrplay_api_Tuner_A;
    dev.rspDuoMode     = sdrplay_api_RspDuoMode_Single_Tuner; }
  dev.rspDuoSampleFreq = 0.0;

  err = sdrplay_api_SelectDevice(&dev);
  if (err != sdrplay_api_Success)
  { printf("SelectDevice() failed: %s\n", sdrplay_api_GetErrorString(err)); sdrplay_api_Close(); return 1; }

  sdrplay_api_DeviceParamsT *params = NULL;
  err = sdrplay_api_GetDeviceParams(dev.dev, &params);
  if (err != sdrplay_api_Success || params == NULL)
  { printf("GetDeviceParams() failed\n"); sdrplay_api_ReleaseDevice(&dev); sdrplay_api_Close(); return 1; }

  if (DualMode)
  { params->devParams->fsFreq.fsHz = DualFs;
    RateHz = DualFs / (double)DualDec;       /* what each tuner actually delivers */ }
  else
  { params->devParams->fsFreq.fsHz          = RateHz; }
  params->devParams->mode                 = BulkMode ? sdrplay_api_BULK : sdrplay_api_ISOCH;
  params->rxChannelA->tunerParams.rfFreq.rfHz = FreqHz;
  params->rxChannelA->tunerParams.rfFreq.syncUpdate = 1;
  params->rxChannelA->tunerParams.bwType  = DualMode ? DualBw : sdrplay_api_BW_1_536;
  params->rxChannelA->tunerParams.ifType  = DualMode ? DualIf : sdrplay_api_IF_Zero;
  params->rxChannelA->tunerParams.gain.gRdB      = GainRedDB;
  params->rxChannelA->tunerParams.gain.LNAstate  = (unsigned char)LnaState;
  params->rxChannelA->tunerParams.gain.minGr     = sdrplay_api_NORMAL_MIN_GR;
  params->rxChannelA->ctrlParams.agc.enable = sdrplay_api_AGC_DISABLE;
  if (BiasTee)
  { params->rxChannelA->rspDuoTunerParams.biasTEnable = 1;
    printf("bias tee     : 4.7 V enabled on the Tuner 2 port\n"); }

  /* On-chip decimation. The ADC cannot run below 2 MHz, so this is the only way to get a lower
     output rate; asking for one directly makes Init() fail. */
  if (Deci > 1)
  { params->rxChannelA->ctrlParams.decimation.enable = 1;
    params->rxChannelA->ctrlParams.decimation.decimationFactor = (unsigned char)Deci;
    printf("decimation  : factor %d requested\n", Deci); }
  else
  { params->rxChannelA->ctrlParams.decimation.enable = 0;
    params->rxChannelA->ctrlParams.decimation.decimationFactor = 1; }

  double OutRate = RateHz / (double)(Deci > 1 ? Deci : 1);
  printf("\ntuning      : %9.3f MHz, %5.3f MSps%s, IF gain reduction %d dB, LNA state %d\n",
         FreqHz / 1e6, OutRate / 1e6,
         (Deci > 1) ? " (decimation factor applied)" : "", GainRedDB, LnaState);
  printf("capturing   : %zu samples (%.2f s)\n", Requested, (double)Requested / RateHz);

  Capture C;
  memset(&C, 0, sizeof(C));
  pthread_mutex_init(&C.Lock, NULL);
  pthread_cond_init(&C.Cond, NULL);
  C.RawCap = Requested;
  C.RawI   = (short *)malloc(Requested * sizeof(short));
  C.RawQ   = (short *)malloc(Requested * sizeof(short));
  C.Shift  = Shift;
  if (OutPath)
  { C.OutCap = 2 * Requested;
    C.Out    = (uint8_t *)malloc(C.OutCap); }
  if (!C.RawI || !C.RawQ || (OutPath && !C.Out))
  { printf("out of memory for %zu samples\n", Requested); return 1; }

  /* Tuner B gets its own capture, sized like A, so the two never share state. */
  Capture CB;
  memset(&CB, 0, sizeof(CB));
  pthread_mutex_init(&CB.Lock, NULL);
  pthread_cond_init(&CB.Cond, NULL);
  if (DualMode)
  { CB.RawCap = Requested;
    CB.RawI   = (short *)malloc(Requested * sizeof(short));
    CB.RawQ   = (short *)malloc(Requested * sizeof(short));
    CB.Shift  = Shift;
    if (OutPath) { CB.OutCap = 2 * Requested; CB.Out = (uint8_t *)malloc(CB.OutCap); }
    if (!CB.RawI || !CB.RawQ || (OutPath && !CB.Out))
    { printf("out of memory for tuner B\n"); return 1; }
    CaptureBPtr = &CB; }

  sdrplay_api_CallbackFnsT cbs;
  cbs.StreamACbFn = stream_a_cb;
  cbs.StreamBCbFn = NULL;
  cbs.EventCbFn   = event_cb;

  if (DualMode) cbs.StreamBCbFn = stream_b_cb;

  err = sdrplay_api_Init(dev.dev, &cbs, &C);
  if (err != sdrplay_api_Success)
  { printf("Init() failed: %s\n", sdrplay_api_GetErrorString(err));
    sdrplay_api_ReleaseDevice(&dev); sdrplay_api_Close(); return 1; }

  /* sdrplay_api_Init() resets channel B to channel A's settings, so tuner B's own frequency has
     to be written after Init and pushed down with a tuner-B update. Without this both tuners
     receive the same band and dual mode looks like it works while proving nothing. */
  if (DualMode)
  { params->rxChannelB->tunerParams.rfFreq.rfHz = FreqB;
    err = sdrplay_api_Update(dev.dev, sdrplay_api_Tuner_B,
                             sdrplay_api_Update_Tuner_Frf, sdrplay_api_Update_Ext1_None);
    if (err != sdrplay_api_Success)
    { printf("sdrplay_api_Update(Tuner_B) failed: %s\n", sdrplay_api_GetErrorString(err));
      sdrplay_api_Uninit(dev.dev); sdrplay_api_ReleaseDevice(&dev); sdrplay_api_Close(); return 1; }
    printf("tuner B     : %9.3f MHz (re-applied after Init)\n", FreqB / 1e6); }

  /* Wait for the capture to fill, but never forever. */
  pthread_mutex_lock(&C.Lock);
  while (C.RawCount < C.RawCap && !Stop)
    pthread_cond_wait(&C.Cond, &C.Lock);
  pthread_mutex_unlock(&C.Lock);

  /* In dual mode both tuners have to fill, and they are separate condition variables, so wait on
     B separately rather than assuming A finishing means B did too. */
  if (DualMode)
  { pthread_mutex_lock(&CB.Lock);
    while (CB.RawCount < CB.RawCap && !Stop)
      pthread_cond_wait(&CB.Cond, &CB.Lock);
    pthread_mutex_unlock(&CB.Lock); }

  sdrplay_api_Uninit(dev.dev);

  size_t n = C.RawCount;
  printf("\ncaptured    : %zu samples\n", n);

  if (n == 0)
  { printf("  -> nothing arrived; the stream never started\n"); }
  else
  { /* The measurement that settles the conversion scale. */
    short imin = C.RawI[0], imax = C.RawI[0], qmin = C.RawQ[0], qmax = C.RawQ[0];
    double si = 0, sq = 0;
    for (size_t i = 0; i < n; i++)
    { if (C.RawI[i] < imin) imin = C.RawI[i];
      if (C.RawI[i] > imax) imax = C.RawI[i];
      if (C.RawQ[i] < qmin) qmin = C.RawQ[i];
      if (C.RawQ[i] > qmax) qmax = C.RawQ[i];
      si += C.RawI[i]; sq += C.RawQ[i]; }
    si /= (double)n; sq /= (double)n;

    printf("raw I       : min %6d  max %6d  mean %9.2f\n", imin, imax, si);
    printf("raw Q       : min %6d  max %6d  mean %9.2f\n", qmin, qmax, sq);

    int peak = abs(imin) > abs(imax) ? abs(imin) : abs(imax);

    /* RMS in dBFS, relative to the full 16-bit scale. This is the number that says whether the
       gain is set sensibly: a well-scaled 8-bit stream wants to sit some way below 0 dBFS, and a
       reading 20 dB low means four of the eight bits are being wasted. */
    double sumsq = 0;
    for (size_t i = 0; i < n; i++)
      sumsq += (double)C.RawI[i] * (double)C.RawI[i] + (double)C.RawQ[i] * (double)C.RawQ[i];
    double rms = sqrt(sumsq / (2.0 * (double)n));
    double rms_db = 20.0 * log10(rms / 32768.0 + 1e-12);
    printf("peak        : %d  (%.1f dBFS; a full-scale 16-bit stream peaks near 32767)\n",
           peak, 20.0 * log10((double)peak / 32768.0 + 1e-12));
    printf("rms         : %.1f  (%.1f dBFS)\n", rms, rms_db);
    printf("headroom    : %.1f dB of the 8-bit range unused above this signal\n",
           -(20.0 * log10((double)peak / 32768.0 + 1e-12)));

    /* The rate actually delivered. A stream that runs slow here starves ogn-rf's time-slot
       reader, which shows up there as "Half time slot" and "Dropped a slot" rather than as
       anything obviously about sample rate. */
    double Span = C.TLast - C.TFirst;
    if (Span > 0.01)
      printf("rate        : %.3f Msps delivered (%.3f Msps requested, %+.1f%%)\n",
             (double)C.NTimed / Span / 1e6, RateHz / 1e6,
             100.0 * ((double)C.NTimed / Span / RateHz - 1.0));

    /* Quantisation: which low bits are always zero. This settles the conversion scale outright,
       which the peak alone cannot do - a weak signal also has a small peak. If every value is a
       multiple of 16 the stream is 12-bit shifted left by 4; a multiple of 4 means 14-bit shifted
       by 2; arbitrary values mean the full 16-bit scale. */
    int mult2=1, mult4=1, mult16=1;
    for (size_t i = 0; i < n; i++)
    { int v = C.RawI[i]; if (v < 0) v = -v;
      if (v & 1)  mult2  = 0;
      if (v & 3)  mult4  = 0;
      if (v & 15) mult16 = 0;
      if (!mult2) break; }
    printf("quantise    : values all even=%s, all multiple of 4=%s, all multiple of 16=%s\n",
           mult2 ? "yes" : "no", mult4 ? "yes" : "no", mult16 ? "yes" : "no");
    printf("shift %d    : %s\n", C.Shift,
           mult16 ? "12-bit data left-justified - shift 8 is correct"
         : mult4  ? "14-bit data left-justified - shift 8 is correct"
         : mult2  ? "15-bit data left-justified - shift 8 is correct"
         :          "full 16-bit scale in use - shift 8 is correct");
    if (peak < 16384)
      printf("              NOTE: this capture is %.1f dB below full scale, so raise the gain;\n"
             "              the unused low bits above are lost resolution, not a scale error\n",
             -(20.0 * log10((double)peak / 32768.0 + 1e-12)));

    long clipped = C.ClippedLow + C.ClippedHigh;
    if (OutPath)
      printf("clipping    : %ld of %zu values (%.3f%%) railed at 0 or 255\n",
             clipped, 2 * n, 100.0 * (double)clipped / (double)(2 * n));

    if (OutPath)
    { FILE *f = fopen(OutPath, "wb");
      if (!f) printf("cannot write %s\n", OutPath);
      else
      { size_t wrote = fwrite(C.Out, 1, C.OutCount, f);
        fclose(f);
        printf("wrote       : %zu bytes of interleaved u8 I/Q to %s\n", wrote, OutPath);
        printf("              analyse with:  python3 tools/spectrum.py %s --rate %.0f --freq %.0f\n",
               OutPath, RateHz, FreqHz); } } }

  /* In dual mode, show that the second tuner really streamed and what it carried. Two tuners on
     the same frequency would produce the same statistics, which is exactly the failure mode the
     post-Init reconfiguration exists to avoid, so report both explicitly. */
  if (DualMode)
  { size_t nb = CB.RawCount;
    printf("\n--- tuner B (%9.3f MHz) ---\n", FreqB / 1e6);
    printf("captured    : %zu samples\n", nb);
    if (nb == 0)
      printf("  -> nothing arrived on tuner B\n");
    else
    { int bimin = CB.RawI[0], bimax = CB.RawI[0];
      double bsumsq = 0;
      for (size_t i = 0; i < nb; i++)
      { int v = CB.RawI[i]; if (v < bimin) bimin = v; if (v > bimax) bimax = v;
        bsumsq += (double)CB.RawI[i]*(double)CB.RawI[i] + (double)CB.RawQ[i]*(double)CB.RawQ[i]; }
      int bpeak = abs(bimin) > abs(bimax) ? abs(bimin) : abs(bimax);
      double brms = sqrt(bsumsq / (2.0 * (double)nb));
      printf("raw I       : min %6d  max %6d\n", bimin, bimax);
      printf("peak        : %d  (%.1f dBFS)\n", bpeak, 20.0*log10((double)bpeak/32768.0+1e-12));
      printf("rms         : %.1f  (%.1f dBFS)\n", brms, 20.0*log10(brms/32768.0+1e-12));
      double span_b = CB.TLast - CB.TFirst;
      if (span_b > 0.01)
        printf("rate        : %.3f Msps delivered\n", (double)CB.NTimed / span_b / 1e6); }
    if (OutPath && CB.Out)
    { char bpath[1024];
      snprintf(bpath, sizeof(bpath), "%s.B.u8", OutPath);
      FILE *bf = fopen(bpath, "wb");
      if (bf) { fwrite(CB.Out, 1, CB.OutCount, bf); fclose(bf);
                printf("\ntuner B I/Q written to %s\n", bpath);
                printf("  analyse with: python3 tools/spectrum.py %s --rate %.0f --freq %.0f\n",
                       bpath, RateHz, FreqB); } }
    free(CB.Out); free(CB.RawI); free(CB.RawQ);
    pthread_mutex_destroy(&CB.Lock); pthread_cond_destroy(&CB.Cond); }

  sdrplay_api_ReleaseDevice(&dev);
  sdrplay_api_Close();

  free(C.RawI); free(C.RawQ); free(C.Out);
  pthread_mutex_destroy(&C.Lock); pthread_cond_destroy(&C.Cond);
  return 0; }
