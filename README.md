# audio-booster

[![test](https://github.com/carlostapiacl/subele/actions/workflows/test.yml/badge.svg)](https://github.com/carlostapiacl/subele/actions/workflows/test.yml)
[![license](https://img.shields.io/badge/license-MIT-222)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14.2%2B-222)](#requisitos)
[![sin dependencias](https://img.shields.io/badge/dependencias-0-222)](Package.swift)

**Español** · [English](README.en.md)

**Sube macOS más allá del 100% sin instalar drivers, y sin que suene a parlante
reventado.**

Una app de barra de menú. Movés el slider, el sistema suena más fuerte. Lo raro
está abajo: ninguna extensión de kernel, ningún driver de audio, y tu dispositivo
de salida por defecto nunca queda secuestrado.

---

## Por qué existe

Todos los amplificadores de volumen de macOS funcionan igual desde hace una
década. Boom 3D, eqMac y el resto instalan un `AudioServerPlugIn` en
`/Library/Audio/Plug-Ins/HAL`, se ponen como salida por defecto del sistema y
pasan el audio hacia el hardware real. Eso implica un driver que firmar, un
instalador, `sudo`, tu salida secuestrada sin avisar, y algo que se rompe cada vez
que Apple saca una actualización.

**macOS 14.2 volvió todo eso innecesario.** `AudioHardwareCreateProcessTap` es una
API pública que captura lo que otros procesos están reproduciendo, sin driver de
por medio. Este proyecto está construido sobre eso.

|  | boosters con driver | audio-booster |
| --- | --- | --- |
| Instala driver | sí, con `sudo` | no |
| Toma la salida por defecto | sí | **no** |
| Al subir el volumen | ganancia cruda, después clipping | limitador con lookahead, sin clipping |
| Control por aplicación | no | posible (el tap acepta lista de procesos) |
| Desinstalar | sacar el driver | borrar la app |

La segunda fila es la que se siente. Multiplicar una señal por tres significa que
todo lo que pasaba de un tercio de escala queda con las puntas cortadas, y una
onda cortada es ese sonido fino y a lata del "volumen aumentado". Un limitador que
ve el pico antes de que llegue no tiene que cortar nada.

## Cómo funciona

```
procesos del sistema ──┐
                       ├──→ [ process tap ] ──→ IOProc ──→ ganancia
                       │      silenciado                       ↓
                       │      al tapearse        compresor + makeup   (modo loudness)
                       │                                       ↓
                       │                    limitador brickwall, 3 ms de lookahead
                       │                                       ↓
este proceso ──────────┴──── excluido del tap ────→ dispositivo de salida
```

1. Un **process tap** captura todo lo que va al dispositivo de salida por defecto,
   con nuestro propio proceso excluido — si no, lo que escribimos se capturaría y
   volvería a entrar. `muteBehavior = .mutedWhenTapped` silencia el camino
   original, así el audio se escucha una vez, a través nuestro.
2. Un **dispositivo agregado privado** junta el tap (entrada) con el hardware real
   (salida), así un solo callback del IOProc tiene las dos puntas.
3. El callback procesa y escribe de vuelta.

La salida por defecto del sistema nunca cambia. El menú de volumen sigue diciendo
"MacBook Pro (bocinas)", porque siguen siendo las bocinas del MacBook Pro.

## El limitador

Esta es la parte por la que vale la pena leer el código.

1. La señal se retrasa 3 ms.
2. Para cada frame que entra se calcula la ganancia que ese frame necesitaría para
   no pasar el techo.
3. Una **cola monótona** mantiene el mínimo corrido de esas ganancias sobre toda
   la ventana de lookahead, en O(1) amortizado por muestra.
4. El frame que sale de la línea de retardo se multiplica por la ganancia más baja
   que vaya a exigir cualquier frame entre él y el presente.

El paso 3 es el que es fácil de errar, y este proyecto lo erró primero. Suavizar
la ganancia con ataque y release en vez de tomar el mínimo de la ventana deja que
el release vaya subiendo la ganancia durante esos 3 ms. El limitador entonces
desborda unos 0,3 dB — suficiente para llegar a fondo de escala y clipear, en
silencio, justo en los transitorios fuertes que uno quería proteger. Con el mínimo
de la ventana, desbordar es imposible por construcción y no por haber ajustado
constantes hasta que se viera bien.

Hay un test para eso: una señal que salta de silencio a fondo de escala con 400%
de ganancia aterriza en el techo, no lo atraviesa.

## Modos

- **Transparente** — solo ganancia y limitación. Dinámica intacta: lo que sonaba
  fuerte respecto de lo que sonaba bajo sigue igual. Para música.
- **Loudness** — agrega compresión con makeup automático, que sube lo bajo en vez
  de aplastar lo alto. Para voz, llamadas y video con audio flojo.

El makeup no es un detalle, es la razón misma de poner un compresor ahí. Un
compresor sin makeup hace el audio *más bajo*. La primera versión de este DSP
salió con ese error y medía más bajo a 300% de ganancia que a 100%. También hay un
test que lo deja clavado.

## Latencia

La cadena cuesta unos **dos períodos de buffer más los 3 ms de lookahead**. Esa
proporción se mantuvo en todos los tamaños de buffer medidos, así que el tamaño de
buffer es la única palanca que la mueve de verdad. Medido sobre los timestamps del
propio IOProc, no estimado:

| buffer | latencia agregada |
| --- | --- |
| 128 frames | 8,8 ms |
| **256 frames (default)** | **14,6 ms** |
| 512 frames (lo que elige CoreAudio) | 26,2 ms |

A la música no le va a importar en ninguno de los tres. Al video puede que sí:
26 ms es más o menos donde el desfase de labios empieza a notarse, y por eso el
default es 256 y no lo que CoreAudio entrega solo. El ajuste está en **Latencia**,
dentro del menú.

## Idioma

La interfaz viene en español e inglés, con selector en el menú (**Idioma**). Por
defecto sigue al idioma del sistema. La consola usa el mismo ajuste.

## Requisitos

macOS 14.2 o posterior y la cadena de herramientas de Swift. Las Command Line
Tools de Xcode alcanzan: este proyecto se compila sin Xcode.

## Instalación

```bash
git clone https://github.com/carlostapiacl/subele
cd audio-booster
./build-app.sh
open "Audio Booster.app"
```

`build-app.sh` compila release, corre los tests, genera el ícono, arma el `.app` a
mano (SwiftPM no produce bundles) y lo firma ad-hoc. La firma ad-hoc alcanza para
correrlo en la máquina que lo compiló; distribuirlo pediría un certificado
Developer ID y notarización.

El ícono se genera por código en `Tools/make-icon.swift`, así que se revisa en
diff como cualquier otro archivo en vez de ser un binario opaco. Dibuja un dial
que pasa del máximo —arco blanco hasta el tope, ámbar siguiendo más allá— con un
parlante al centro. El ámbar es el mismo color que usa el medidor cuando el
limitador trabaja. El de la barra de menú repite la idea en monocromo, y **el arco
crece con la ganancia**: dice cuánto está amplificando sin que haya que leer el
porcentaje.

## Uso

Aparece un ícono de parlante en la barra de menú. Al abrirlo: el dispositivo de
salida y su formato, un medidor de nivel que se pone naranja mientras el limitador
trabaja, un slider de 50 a 400%, el selector de modo, la latencia y el idioma.

La ganancia, el modo, la latencia y el idioma se guardan entre sesiones.

Un binario, dos caras — el bundle `.app` solo lo envuelve:

```bash
booster              # app de barra de menú
booster --cli        # consola interactiva
booster --cli --buffer 128
booster --help
```

`BOOSTER_TRACE=1` traza cada paso del arranque a stderr. Las llamadas a CoreAudio
pueden bloquearse indefinidamente sin devolver error, y con stdout bufferizado un
cuelgue así no deja ningún rastro.

## Tests

```bash
swift test
```

Los tests del DSP son procesamiento de señal puro — sin dispositivo de audio, sin
tap, sin permisos — así que corren en CI igual que en un laptop. Eso es
deliberado: medir por los parlantes no sirve, porque cualquier otra cosa que suene
en la máquina se mezcla en el tap y contamina el medidor. Se perdieron dos rondas
de mediciones por música de fondo antes de que los tests se fueran del hardware.

Lo que dejan clavado: ganancia exacta mientras haya headroom, el limitador
llegando al techo pero nunca pasándolo, transitorios de silencio a fondo de
escala, salida idéntica bit a bit entre bloques de 32 y de 1024, todos los conteos
de canales de mono a 7.1, y NaN o infinito llegando a la entrada sin matar la
cadena.

## Limitaciones conocidas

- **Otro booster con driver lo cuelga.** Si eqMac o Boom 3D está corriendo, es
  dueño de la salida por defecto, así que tapeamos *su* dispositivo virtual, que a
  su vez está pasando audio. `AudioDeviceCreateIOProcIDWithBlock` entonces bloquea
  para siempre sin dar error. Hay que cerrarlo primero.
- **Los parámetros se escriben sin sincronizar.** `gain` y `mode` los escribe el
  hilo de la interfaz y los lee el hilo de audio. En x86-64 y arm64 una carga o
  guarda alineada de 4 bytes es atómica en hardware, así que en la práctica no
  pasa nada, pero formalmente es una carrera de datos. Arreglarlo bien pide
  atómicos.
- **El modo loudness sube el piso de ruido**, porque el makeup también se aplica
  cuando no hay señal. Es inherente al modo, no un defecto.
- **No arranca al iniciar sesión.** A propósito: no se instala un elemento de
  arranque sin que lo pidan.

## Estructura

```
Sources/BoosterKit/          la parte reutilizable, sin AppKit
  CoreAudio/
    AudioObject.swift        envoltorio tipado de la API de propiedades, errores, traza
    AudioDevices.swift       consultas de dispositivos y observación de la salida
    ProcessTap.swift         vida del tap
    AggregateDevice.swift    vida del dispositivo agregado, tamaño de buffer
  DSP/
    Decibels.swift           conversiones a dB y coeficientes de suavizado
    Compressor.swift         curva de rodilla suave y makeup automático
    Limiter.swift            línea de retardo y mínimo deslizante
    BoostProcessor.swift     la cadena
  Engine/
    BoostEngine.swift        tap + agregado + IOProc + medición de latencia
Sources/booster/             el ejecutable
  main.swift                 elige el modo según los argumentos
  MenuBarApp.swift           frente en AppKit
  LevelMeterView.swift
  ConsoleMode.swift
  Strings.swift              todo el texto visible, tipado, en dos idiomas
Tools/make-icon.swift        genera AppIcon.icns
Tests/BoosterKitTests/
```

`BoosterKit` no depende de AppKit ni sabe que existe una interfaz, así que el
motor se puede embeber en otra cosa.

## Licencia

MIT © Carlos Tapia
