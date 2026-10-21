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

// Zoom nativo UVC (Camera Terminal 1, selector 0x0B).
// Valores inteiros em centésimos de zoom: 100=1x, 400=4x
// conforme os limites lidos da Pocket 3 em 21/10/2026.
// ptz_zoom_set valida os limites de hardware antes de cada escrita.
int ptz_zoom_get(int *zoom);
int ptz_zoom_range(int *minimum, int *maximum);
// Escrita com os limites consultados ao conectar, sem 2 GETs em cada arraste.
// Por segurança, não aceita limites fora dos 100..400 confirmados na Pocket 3.
int ptz_zoom_set_checked(int zoom, int minimum, int maximum);
int ptz_zoom_set(int zoom);

#endif
