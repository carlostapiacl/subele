#ifndef CATOMICS_H
#define CATOMICS_H

#include <stdint.h>

// Cargas y guardas atómicas sobre memoria cruda, para los parámetros que escribe
// la interfaz y lee el hilo de audio.
//
// Existe porque el tipo Atomic de Swift (módulo Synchronization) exige macOS 15 y
// este proyecto soporta desde 14.2. Son builtins de clang: ni locks ni llamadas a
// librería, así que se pueden usar desde un IOProc.
//
// Los floats van con orden relajado: cada parámetro vale por sí solo y no publica
// otra memoria. El contador de generación sí usa acquire/release, porque avisa que
// los parámetros del ecualizador cambiaron y esos tienen que verse completos.

static inline float ca_load_float(const float *p) {
    float value;
    __atomic_load(p, &value, __ATOMIC_RELAXED);
    return value;
}

static inline void ca_store_float(float *p, float value) {
    __atomic_store(p, &value, __ATOMIC_RELAXED);
}

static inline uint32_t ca_load_u32(const uint32_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void ca_store_u32(uint32_t *p, uint32_t value) {
    __atomic_store_n(p, value, __ATOMIC_RELEASE);
}

static inline uint32_t ca_increment_u32(uint32_t *p) {
    return __atomic_add_fetch(p, 1, __ATOMIC_ACQ_REL);
}

#endif
