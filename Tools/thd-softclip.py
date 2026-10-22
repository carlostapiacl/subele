#!/usr/bin/env python3
"""Distorsión de un soft limiter por muestra a 400 % de ganancia.

Es la mitad azul del gráfico de la página (docs/index.html, "Sube sin que suene
reventado"). La mitad ámbar, la de Subele, no sale de acá: la mide el test
`boostingDoesNotDistort` en Tests/BoosterKitTests/LimiterTests.swift, con el
procesador real.

El limitador es la fórmula que FineTune publica en
FineTune/Audio/Engine/SoftLimiter.swift (v1.9.0): bajo 0,95 la muestra pasa
igual; sobre 0,95 se comprime asintóticamente hacia 1,0, muestra por muestra.
No es una grabación de la app (eso queda por hacer); es su algoritmo aplicado
a la misma señal de prueba que usa el test de Subele.

    python3 Tools/thd-softclip.py      # necesita numpy
"""
import numpy as np

SAMPLE_RATE = 48_000
FREQUENCY = 1_000
GAIN = 4.0                                   # 400 %
FRAMES = SAMPLE_RATE


def soft_limit(x, threshold=0.95, ceiling=1.0):
    headroom = ceiling - threshold
    magnitude = np.abs(x)
    over = np.maximum(magnitude - threshold, 0)
    limited = np.where(magnitude <= threshold, magnitude,
                       threshold + headroom * (over / (over + headroom)))
    return np.sign(x) * limited


def total_harmonic_distortion(y):
    """THD en %, armónicos 2 a 10, sobre la segunda mitad (ya asentada)."""
    y = y[FRAMES // 2:]
    spectrum = np.abs(np.fft.rfft(y * np.hanning(len(y))))
    def peak(frequency):
        bin_ = int(round(frequency * len(y) / SAMPLE_RATE))
        return spectrum[bin_ - 3:bin_ + 4].max()
    harmonics = np.sqrt(sum(peak(h * FREQUENCY) ** 2 for h in range(2, 11)))
    return 100 * harmonics / peak(FREQUENCY)


if __name__ == "__main__":
    t = np.arange(FRAMES) / SAMPLE_RATE
    for decibels in (-12, -6, 0):
        x = 10 ** (decibels / 20) * np.sin(2 * np.pi * FREQUENCY * t) * GAIN
        print(f"entra a {decibels:>3} dBFS, 400 %: THD {total_harmonic_distortion(soft_limit(x)):.1f} %")
