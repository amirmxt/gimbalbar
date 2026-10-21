#ifndef PTZ_H
#define PTZ_H

// UVC Pan/Tilt Absolute on the DJI Osmo Pocket 3 webcam, via IOKit.
// All functions return 0 on success. Angles are in degrees.

typedef struct {
  double panMin, panMax, tiltMin, tiltMax;
} ptz_range_t;

int ptz_get(double *pan, double *tilt);
int ptz_set(double pan, double tilt);
int ptz_range(ptz_range_t *out);

// Native UVC zoom (Camera Terminal 1, selector 0x0B).
// Integer zoom units are hundredths: 100=1x, 400=4x
// based on the range reported by the tested Pocket 3.
// ptz_zoom_set valida os limites de hardware antes de cada escrita.
int ptz_zoom_get(int *zoom);
int ptz_zoom_range(int *minimum, int *maximum);
// Write using bounds queried on connect instead of two GETs per drag step.
// Reject ranges outside the verified Pocket 3 interval of 100..400.
int ptz_zoom_set_checked(int zoom, int minimum, int maximum);
int ptz_zoom_set(int zoom);

#endif
