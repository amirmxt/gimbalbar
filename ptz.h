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

#endif
