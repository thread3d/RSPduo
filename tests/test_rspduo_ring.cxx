/*
 * test_rspduo_ring.cxx - host-side unit test for the rspduo.h ring-buffer bridge
 *
 * The riskiest part of the RSPduo backend is not its configuration calls, which are checked by
 * the compiler and then confirmed by the probe: it is the bridge from the SDRplay API's callback
 * thread to ogn-rf's blocking Read(). That code can be exercised with no hardware and no vendor
 * library at all, by stubbing the handful of sdrplay_api_* entry points rspduo.h calls, and
 * driving the registered stream callback directly.
 *
 * What this checks:
 *   - Open() parses the device description and succeeds through the stub
 *   - the int16 -> interleaved u8 conversion, including the 128 offset and the clamping
 *   - Read() returns exactly what was asked for and interleaves I and Q in the right order
 *   - a stream reset flushes the ring rather than splicing two configurations together
 *   - a ring overrun is counted, rather than silently dropping or corrupting data
 *
 * It does NOT check anything that depends on real hardware: tuning, gain, sample rate accuracy or
 * the API's own behaviour. Those need the probe on the box.
 *
 * Two things about the backend that this test has to respect rather than assume:
 *
 *   - Read() rounds the requested count down to a multiple of 256, exactly as rtlsdr.h and
 *     limesdr.h do. So every request below asks for a multiple of 256.
 *   - rspduo.h passes a stack-local sdrplay_api_CallbackFnsT to sdrplay_api_Init(). That is fine
 *     with the real library, which copies it, but a stub must copy the struct by value too; saving
 *     the pointer leaves the test with a dangling reference as soon as Open() returns.
 *
 * Build and run (from the repository root):
 *     g++ -O1 -Wall -I<ogn-rf checkout> -I<path-to-sdrplay-headers> -o test_rspduo_ring \
 *         tests/test_rspduo_ring.cxx -lpthread
 *     ./test_rspduo_ring
 *
 * The vendored headers are needed; the vendor library is not.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

#include <sdrplay_api.h>

/* ---------------------------------------------------------------------------------------------
 * Stubs for the vendor API.
 * ------------------------------------------------------------------------------------------- */

static sdrplay_api_DeviceParamsT    StubParams;
static sdrplay_api_DevParamsT       StubDevParams;
static sdrplay_api_RxChannelParamsT StubChannelA;
static sdrplay_api_RxChannelParamsT StubChannelB;

/* Copied BY VALUE: see the note in the header comment. */
static sdrplay_api_CallbackFnsT StubCbs;
static int  StubHaveCbs   = 0;
static void *StubCtx      = NULL;
static int  StubInitCalls = 0;
static int  StubUninitCalls = 0;

extern "C" {

sdrplay_api_ErrT sdrplay_api_Open(void)             { return sdrplay_api_Success; }
sdrplay_api_ErrT sdrplay_api_Close(void)            { return sdrplay_api_Success; }
sdrplay_api_ErrT sdrplay_api_LockDeviceApi(void)    { return sdrplay_api_Success; }
sdrplay_api_ErrT sdrplay_api_UnlockDeviceApi(void)  { return sdrplay_api_Success; }

sdrplay_api_ErrT sdrplay_api_ApiVersion(float *apiVer)
{ if (apiVer) *apiVer = SDRPLAY_API_VERSION; return sdrplay_api_Success; }

const char *sdrplay_api_GetErrorString(sdrplay_api_ErrT err)
{ (void)err; return "stub error"; }

sdrplay_api_ErrT sdrplay_api_GetDevices(sdrplay_api_DeviceT *devices, unsigned int *numDevs,
                                        unsigned int maxDevs)
{ if (numDevs) *numDevs = 1;
  if (devices && maxDevs >= 1)
  { memset(&devices[0], 0, sizeof(devices[0]));
    devices[0].hwVer = SDRPLAY_RSPduo_ID;
    devices[0].valid = 1;
    strncpy(devices[0].SerNo, "STUB0001", SDRPLAY_MAX_SER_NO_LEN - 1); }
  return sdrplay_api_Success; }

sdrplay_api_ErrT sdrplay_api_SelectDevice(sdrplay_api_DeviceT *device)
{ if (device) device->dev = (HANDLE)0xBEEF; return sdrplay_api_Success; }

sdrplay_api_ErrT sdrplay_api_ReleaseDevice(sdrplay_api_DeviceT *device)
{ if (device) device->dev = NULL; return sdrplay_api_Success; }

sdrplay_api_ErrT sdrplay_api_GetDeviceParams(HANDLE dev, sdrplay_api_DeviceParamsT **deviceParams)
{ (void)dev;
  memset(&StubDevParams, 0, sizeof(StubDevParams));
  memset(&StubChannelA, 0, sizeof(StubChannelA));
  StubParams.devParams  = &StubDevParams;
  memset(&StubChannelB, 0, sizeof(StubChannelB));
  StubParams.rxChannelA = &StubChannelA;
  StubParams.rxChannelB = &StubChannelB;
  if (deviceParams) *deviceParams = &StubParams;
  return sdrplay_api_Success; }

sdrplay_api_ErrT sdrplay_api_Init(HANDLE dev, sdrplay_api_CallbackFnsT *callbackFns, void *cbContext)
{ (void)dev;
  if (callbackFns) { StubCbs = *callbackFns; StubHaveCbs = 1; }
  StubCtx = cbContext; StubInitCalls++;
  return sdrplay_api_Success; }

sdrplay_api_ErrT sdrplay_api_Uninit(HANDLE dev) { (void)dev; StubUninitCalls++; return sdrplay_api_Success; }

sdrplay_api_ErrT sdrplay_api_Update(HANDLE dev, sdrplay_api_TunerSelectT tuner,
                                    sdrplay_api_ReasonForUpdateT reason,
                                    sdrplay_api_ReasonForUpdateExtension1T ext1)
{ (void)dev; (void)tuner; (void)reason; (void)ext1; return sdrplay_api_Success; }

} /* extern "C" */

/* --------------------------------------------------------------------------------------------- */

#include "buffer.h"
#include "thread.h"
#include "rspduo.h"

static int Failures = 0;
static int Checks   = 0;

static void check(int ok, const char *what)
{ Checks++;
  if (ok) printf("  pass  %s\n", what);
  else { printf("  FAIL  %s\n", what); Failures++; } }

/* Feed samples into the backend exactly as the API would. */
static void feed(const short *xi, const short *xq, unsigned int n, unsigned int reset)
{ if (StubHaveCbs && StubCbs.StreamACbFn)
    StubCbs.StreamACbFn((short *)xi, (short *)xq, NULL, n, reset, StubCtx);
  else { printf("  FAIL  the backend never registered a stream callback\n"); Failures++; } }

/* Fill a buffer with N samples of a constant value, so blocks can be told apart. */
static void fill(short *xi, short *xq, unsigned int n, short vi, short vq)
{ for (unsigned int i = 0; i < n; i++) { xi[i] = vi; xq[i] = vq; } }

/* Check that a whole read buffer holds one constant converted value. */
static int all_equal(const uint8_t *buf, unsigned int samples, uint8_t vi, uint8_t vq)
{ for (unsigned int i = 0; i < samples; i++)
    if (buf[2 * i] != vi || buf[2 * i + 1] != vq) return 0;
  return 1; }

int main(void)
{
  printf("rspduo.h ring-buffer bridge\n===========================\n");

  /* ----------------------------------------------------------------------------------------- */
  printf("\nOpen()\n");
  RSPDuo Radio;
  int r = Radio.Open(0, 868300000, 2000000);
  check(r > 0, "Open() succeeds through the stub");
  check(StubInitCalls == 1, "sdrplay_api_Init() was called exactly once");
  check(Radio.isOpen(), "the backend reports itself open");
  check(strcmp(Radio.getDeviceName(), "RSPduo") == 0, "the device is identified as an RSPduo");
  check(strcmp(Radio.DeviceSerNo, "STUB0001") == 0, "the serial is reported");
  check(fabs(Radio.SampleRateApplied - 2000000.0) < 1.0, "2 MSps is accepted as-is, not snapped");
  check(StubHaveCbs && StubCbs.StreamACbFn != NULL, "a stream callback was registered");

  /* ----------------------------------------------------------------------------------------- */
  printf("\nConversion: int16 -> interleaved u8 with 128 as zero\n");
  { /* A clean ramp: xi[i] = (i-128)<<8 converts to exactly i, and Q is a constant zero.
       (i-128)<<8 lies in -32768..32512, so this stays inside int16. */
    const unsigned int N = 256;
    short xi[N], xq[N];
    for (unsigned int i = 0; i < N; i++) { xi[i] = (short)(((int)i - 128) << 8); xq[i] = 0; }
    feed(xi, xq, N, 0);

    uint8_t buf[2 * N];
    memset(buf, 0xAA, sizeof(buf));
    int got = Radio.Read(buf, (int)N);
    check(got == (int)N, "Read() returns the number of samples asked for");

    int ramp_ok = 1;
    for (unsigned int i = 0; i < N; i++) if (buf[2 * i] != (uint8_t)i) { ramp_ok = 0; break; }
    check(ramp_ok, "I lands in the even bytes, in order, offset by 128");

    int q_ok = 1;
    for (unsigned int i = 0; i < N; i++) if (buf[2 * i + 1] != 128) { q_ok = 0; break; }
    check(q_ok, "Q lands in the odd bytes"); }

  /* ----------------------------------------------------------------------------------------- */
  printf("\nClamping at both rails\n");
  { const unsigned int N = 256;
    short xi[N], xq[N];
    fill(xi, xq, N, 0, 0);
    xi[0] = 32767;  xq[0] = -32768;      /* the extremes: must rail at 255 and 0 */
    feed(xi, xq, N, 0);

    uint8_t buf[2 * N];
    memset(buf, 0xAA, sizeof(buf));
    int got = Radio.Read(buf, (int)N);
    check(got == (int)N, "Read() returns 256 samples");
    check(buf[0] == 255, "the most positive sample clamps to 255");
    check(buf[1] == 0,   "the most negative sample clamps to 0");
    check(buf[2] == 128 && buf[3] == 128, "the following zero sample is 128"); }

  /* ----------------------------------------------------------------------------------------- */
  printf("\nReset flushes the ring\n");
  { const unsigned int N = 256;
    short xi[N], xq[N];
    uint8_t buf[2 * N];

    /* Block A: everything zero -> 128. Queue it, then reset while queueing the same block:
       the reset must discard the earlier copy, leaving exactly one block readable. */
    fill(xi, xq, N, 0, 0);
    feed(xi, xq, N, 0);
    feed(xi, xq, N, 1);
    memset(buf, 0xAA, sizeof(buf));
    int got = Radio.Read(buf, (int)N);
    check(got == (int)N, "one block is readable after a mid-stream reset");
    check(all_equal(buf, N, 128, 128), "the readable block is the post-reset one");

    /* Now a block that is visibly different, queued with reset: it must be what comes back. */
    fill(xi, xq, N, (short)(1 << 8), 0);       /* converts to 129 */
    feed(xi, xq, N, 1);
    memset(buf, 0xAA, sizeof(buf));
    got = Radio.Read(buf, (int)N);
    check(got == (int)N, "the post-reset block is readable");
    check(all_equal(buf, N, 129, 128), "and it is the new block, not the old one");
 }

  /* ----------------------------------------------------------------------------------------- */
  printf("\nOverrun is counted, not silently swallowed\n");
  { Radio.ResetBuffer();
    uint64_t before = Radio.getOverflows(0);

    /* The ring is 2 MiB = 1 M samples. Push 4 x 300k = 1.2 M samples through it, which cannot
       fit, so the callback must drop and count rather than corrupt. */
    const unsigned int BLOCK = 307200;         /* multiple of 256 */
    short *xi = (short *)malloc(BLOCK * sizeof(short));
    short *xq = (short *)malloc(BLOCK * sizeof(short));
    int allocated = (xi != NULL && xq != NULL);
    check(allocated, "scratch buffers allocated");
    if (allocated)
    { fill(xi, xq, BLOCK, 0, 0);
      /* Push until the ring actually overflows rather than assuming a capacity. The ring is
         sized from the sample rate (two seconds), so a fixed block count silently stopped
         overflowing it the moment that sizing changed - which is exactly what happened. */
      int Blocks = 0;
      for (; Blocks < 64 && Radio.getOverflows(0) == before; Blocks++)
        feed(xi, xq, BLOCK, 0);
      char what[128];
      snprintf(what, sizeof(what), "the overrun was counted in Overflows (after %d blocks)", Blocks);
      check(Radio.getOverflows(0) > before, what);

      uint8_t buf[2 * 256];
      memset(buf, 0xAA, sizeof(buf));
      int got = Radio.Read(buf, 256);
      check(got == 256, "the ring still delivers samples after an overrun");
      check(all_equal(buf, 256, 128, 128), "and the samples are coherent, not torn");
      Radio.ResetBuffer(); }
    free(xi); free(xq); }

  /* ----------------------------------------------------------------------------------------- */
  printf("\nDecimation mapping\n");
  { /* The ADC cannot run below 2 MHz - asking for a lower fsHz makes Init() fail, verified on
       hardware - so every rate below 2 MHz is reached by decimating. SnapSampleRate returns the
       ADC rate to program and sets the factor; the delivered rate is that divided once. */
    struct { double Want; double Adc; int Dec; } Cases[] = {
      { 2000000.0, 2000000.0, 1 }, { 1000000.0, 2000000.0, 2 },
      {  500000.0, 2000000.0, 4 }, {  250000.0, 2000000.0, 8 },
      {  125000.0, 2000000.0, 16}, {   62500.0, 2000000.0, 32},
      { 6000000.0, 6000000.0, 1 }, { 8000000.0, 8000000.0, 1 },
    };
    for (unsigned i = 0; i < sizeof(Cases)/sizeof(Cases[0]); i++)
    { int Dec = 0;
      double Adc = RSPDuo::SnapSampleRate(Cases[i].Want, Dec);
      double Delivered = Adc / (double)Dec;
      char what[160];
      snprintf(what, sizeof(what), "%.0f Hz asked -> ADC %.0f Hz decimated by %d = %.0f Hz",
               Cases[i].Want, Adc, Dec, Delivered);
      int ok = (fabs(Adc - Cases[i].Adc) < 1.0) && (Dec == Cases[i].Dec)
               && (Delivered >= Cases[i].Want * 0.999);
      /* The ADC rate must never be below 2 MHz, or Init() would fail. */
      if (Adc < 2000000.0) ok = 0;
      check(ok, what); } }

  /* ----------------------------------------------------------------------------------------- */
  printf("\nDual mode: both tuners stream independently\n");
  { /* The whole point of dual mode is that the two rings are independent. Drive the A callback
       with one pattern and the B callback with another, and confirm each is read back separately -
       which is what would fail if the API's post-Init channel B reset were not handled. */
    RSPDuo Dual;
    Dual.RspDuoMode = sdrplay_api_RspDuoMode_Dual_Tuner;
    int ok = Dual.Open(0, 868200000, 2000000);
    check(ok > 0, "Open() succeeds in dual-tuner mode");
    check(Dual.haveTunerB(), "the backend reports tuner B as live");
    check(StubHaveCbs && StubCbs.StreamBCbFn != NULL, "a separate tuner B callback was registered");
    check(Dual.getCenterFreqB() != 0, "tuner B has its own centre frequency");

    const unsigned int N = 256;
    short ai[N], aq[N], bi[N], bq[N];
    for (unsigned int i = 0; i < N; i++) { ai[i] = (short)(((int)i - 128) << 8); aq[i] = 0; }
    for (unsigned int i = 0; i < N; i++) { bi[i] = (short)(((int)127 - i) << 8); bq[i] = 0; }

    /* Feed both callbacks: A counts up, B counts down. */
    StubCbs.StreamACbFn(ai, aq, NULL, N, 0, StubCtx);
    StubCbs.StreamBCbFn(bi, bq, NULL, N, 0, StubCtx);

    uint8_t abuf[2 * N], bbuf[2 * N];
    memset(abuf, 0xAA, sizeof(abuf)); memset(bbuf, 0xAA, sizeof(bbuf));
    int ga = Dual.Read(abuf, (int)N, 0);
    int gb = Dual.Read(bbuf, (int)N, 1);
    check(ga == (int)N, "tuner A delivers its samples");
    check(gb == (int)N, "tuner B delivers its samples");

    int a_ok = 1, b_ok = 1;
    for (unsigned int i = 0; i < N; i++)
    { if (abuf[2*i] != (uint8_t)i) a_ok = 0;
      if (bbuf[2*i] != (uint8_t)(255 - (int)i)) b_ok = 0; }
    check(a_ok, "tuner A carries its own stream, not B's");
    check(b_ok, "tuner B carries its own stream, not A's");

    Dual.Close(); }

  /* ----------------------------------------------------------------------------------------- */
  printf("\nSelection diversity\n");
  { /* Both tuners on one frequency; the stronger one must be the one handed to ogn-rf. This is
       the check that matters, because a selection that always returns tuner A would look
       perfectly healthy while providing no diversity at all. */
    const unsigned int N = 1024;
    uint8_t quiet[2 * N], loud[2 * N];

    /* The metric itself first: a near-zero signal must not out-score a large one. */
    memset(quiet, 128, sizeof(quiet));
    for (unsigned int i = 0; i < 2 * N; i++) loud[i] = (uint8_t)(128 + ((i & 1) ? 100 : -100));
    double pq = RSPDuo::BlockPeakPowerdB(quiet, (int)N, 256);
    double pl = RSPDuo::BlockPeakPowerdB(loud,  (int)N, 256);
    char what[128];
    snprintf(what, sizeof(what), "quiet %.0f dB vs loud %.0f dB, loud scores higher", pq, pl);
    check(pl > pq + 20.0, what);

    RSPDuo Div;
    Div.RspDuoMode = sdrplay_api_RspDuoMode_Dual_Tuner;
    Div.setSelectionDiversity(1);
    int ok = Div.Open(0, 868300000, 2000000);
    check(ok > 0, "Open() succeeds with selection diversity requested");
    check(Div.haveDiversity(), "diversity is active");
    check(Div.getCenterFreqB() == Div.getCenterFreq(),
          "both tuners are on the same frequency in diversity mode");

    /* Feed A quietly and B loudly, then ask for a read: B must win. */
    short qi[N], qq[N], li[N], lq[N];
    /* Note the shift: 25000 >> 8 = 97, so 'loud' lands 97 counts from 128 while 'quiet'
       stays at 0. 8000 would give only 31 and the assertion below would be wrong. */
    for (unsigned int i = 0; i < N; i++) { qi[i] = 10; qq[i] = -10; li[i] = 25000; lq[i] = -25000; }
    StubCbs.StreamACbFn(qi, qq, NULL, N, 0, StubCtx);
    StubCbs.StreamBCbFn(li, lq, NULL, N, 0, StubCtx);

    SampleBuffer<uint8_t> Out;
    int got = Div.Read(Out, (int)N, 0);
    check(got == (int)N, "a diversity read returns samples");
    check(Div.getDivLastTuner() == 1, "tuner B wins when it is the stronger one");
    check(Div.getDivChoseB() == 1, "the winner counter agrees");

    /* The data handed back must be B's, not A's: B is large, A is tiny. */
    int peak = 0;
    for (unsigned int i = 0; i < (unsigned int)got; i++)
    { int d = abs((int)Out.Data[2*i] - 128); if (d > peak) peak = d; }
    snprintf(what, sizeof(what), "the returned buffer is tuner B's (peak deviation %d, not ~2)", peak);
    check(peak > 50, what);

    /* Now swap the roles: A loud, B quiet. It must move to A. */
    Div.ResetBuffer();
    StubCbs.StreamACbFn(li, lq, NULL, N, 0, StubCtx);
    StubCbs.StreamBCbFn(qi, qq, NULL, N, 0, StubCtx);
    Div.Read(Out, (int)N, 0);
    check(Div.getDivLastTuner() == 0, "the choice follows the stronger tuner");
    check(Div.getDivSwitches() >= 1, "the switch was counted");
    Div.Close(); }

  /* ----------------------------------------------------------------------------------------- */
  printf("\nClose()\n");
  int uninit_before = StubUninitCalls;
  Radio.Close();
  check(!Radio.isOpen(), "the backend reports itself closed");
  check(StubUninitCalls == uninit_before + 1, "sdrplay_api_Uninit() was called exactly once");
  { uint8_t buf[2 * 256];
    check(Radio.Read(buf, 256) < 0, "Read() on a closed radio fails instead of hanging"); }

  printf("\n===========================\n");
  printf("%d checks, %d failed\n", Checks, Failures);
  return Failures == 0 ? 0 : 1;
}
