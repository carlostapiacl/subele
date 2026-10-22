# Distorsión al subir a 400 %, Subele frente a FineTune

**Fecha:** 22 de octubre de 2026 · **Versiones:** Subele 0.2.2 (sin publicar), FineTune v1.9.0

## Contexto

FineTune hace lo mismo que Subele sin driver, es gratis y tiene 9.840 estrellas. Para la página
necesitaba saber si había algo medible en lo que Subele fuera distinto, porque en funciones FineTune
gana en casi todo (volumen por app, 10 bandas, AutoEQ, ruteo, Homebrew).

## Hipótesis

Los dos evitan pasarse del máximo, pero de forma distinta. FineTune usa un *soft limiter* por
muestra (`FineTune/Audio/Engine/SoftLimiter.swift`): bajo 0,95 la muestra pasa igual, y sobre 0,95 se
comprime hacia 1,0. Eso reforma cada pico, así que al subir mucho debería agregar armónicos. Subele
baja la ganancia entera con 3 ms de anticipación, y la onda no debería cambiar de forma.

## Qué se probó

Un seno de 1 kHz a 48 kHz, con la ganancia en 400 % y tres niveles de entrada. Distorsión armónica
total con los armónicos 2 a 10, sobre la segunda mitad de la señal.

- **Subele:** el procesador real, con el test `boostingDoesNotDistort` de
  `Tests/BoosterKitTests/LimiterTests.swift`. El test de al lado comprueba que el medidor sí ve un
  recorte cuando lo hay, para que un medidor roto no lo haga pasar.
- **FineTune:** su fórmula publicada aplicada a la misma señal, con `Tools/thd-softclip.py`. No es
  una grabación de la app.

## Resultado

| Entrada | Soft limiter de FineTune | Subele |
| --- | --- | --- |
| −12 dBFS | 1,0 % | 0,0004 % |
| −6 dBFS | 23,2 % | 0,0004 % |
| 0 dBFS | 35,4 % | 0,0004 % |

Lo de Subele es ruido numérico. En el caso de −12 dBFS la señal amplificada apenas toca 1,0, por eso
FineTune distorsiona poco ahí.

## Qué no cubre

Es un seno, no música: con música la diferencia cambia, y el limitador de Subele tiene su propia
modulación cuando la ganancia sube y baja. Tampoco se grabó la salida de ninguna de las dos apps.
Las dos cosas quedan por confirmar.

## Decisión

La página y el README usan este resultado como la diferencia de Subele, con el método y el script
enlazados. Se dejó de afirmar que los boosters con driver "usan ganancia cruda y clipping", porque
eso nunca se midió.
