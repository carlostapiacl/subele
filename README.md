# Subele

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

Es gratis y de código abierto. Si te sirve, [se agradece una donación](https://paypal.me/carlostapiacl);
si no, usala igual. *(Antes se llamaba audio-booster.)*

<p align="center"><img src="docs/screenshot-ecualizador.png" width="640" alt="El menú de Subele con el ecualizador gráfico abierto"></p>

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

|  | boosters con driver | Subele |
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
                       │      al tapearse                 ecualizador
                       │                                       ↓
                       │                         compresor + makeup   (modo Voz)
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

- **Música** — solo ganancia y limitación. Dinámica intacta: lo que sonaba
  fuerte respecto de lo que sonaba bajo sigue igual. **Con la ganancia en 100% no
  hace nada, a propósito**: se nota al subir, cuando el limitador empieza a
  trabajar. El panel lo dice debajo del selector, porque fue lo primero que
  preguntó alguien que la probó.
- **Voz** — agrega compresión con makeup automático, que sube lo bajo en vez de
  aplastar lo alto. Para voz, llamadas y video con audio flojo. Este sí se nota
  en 100%.

(En versiones anteriores se llamaban *Transparente* y *Loudness*.)

El makeup no es un detalle, es la razón misma de poner un compresor ahí. Un
compresor sin makeup hace el audio *más bajo*. La primera versión de este DSP
salió con ese error y medía más bajo a 300% de ganancia que a 100%. También hay un
test que lo deja clavado.

## Ecualizador

Cinco bandas, ±12 dB: un shelf de graves en 60 Hz, campanas en 250 Hz, 1 kHz y
4 kHz, y un shelf de agudos en 12 kHz. Son biquads del cookbook de Robert
Bristow-Johnson con estado en doble precisión, y van **antes** del compresor y del
limitador: subir los graves agrega energía, y puesto ahí el limitador ve ese pico
como cualquier otro en vez de dejarlo clipear.

Se maneja como gráfico: la curva de respuesta real —calculada con los mismos
biquads que procesan el audio, así que lo que se ve es lo que suena— con un punto
por banda que se arrastra, doble clic para volverlo a cero y la rueda del mouse
para ajuste fino. Detrás corre el espectro de lo que está sonando (FFT de 4096
puntos con Accelerate, en el hilo de la interfaz y solo con el ecualizador
abierto). Trae presets como punto de partida: Plano, Más graves, Voz clara, Más
brillo, Noche y Parlantes de laptop.

Con todas las bandas en 0 dB la salida es idéntica bit a bit a la entrada. Hay un
test para eso, otro que comprueba que cada banda sube lo que dice y otro que lo
pone todo a +12 dB en cinco frecuencias de muestreo para ver que nada se vuelva
inestable.

## Frecuencia de muestreo

El menú **Frecuencia de muestreo** cambia la salida entre las frecuencias que
acepte el dispositivo (44,1, 48, 96 kHz…), lo mismo que hacerlo en Configuración
de Audio MIDI, pero sin saber que esa app existe. El cambio es para todo el
sistema, y la cadena se rehace sola cuando el dispositivo lo termina de aplicar,
también si se cambia desde afuera.

Lo que gana y lo que no: subir de 44,1 a 96 kHz no le agrega detalle a una
grabación de 44,1. Lo que puede cambiar es que macOS deje de convertir de
frecuencia y que la interfaz suene distinto a la frecuencia que prefiere. Hay
gente que lo nota mucho, y antes había que ir a buscarlo a una app escondida.

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

macOS 14.2 o posterior, Intel o Apple Silicon (el `.dmg` trae un binario
universal), y la cadena de herramientas de Swift para compilar. Las Command Line
Tools de Xcode alcanzan: este proyecto se compila sin Xcode.

## Instalación

### Descargar

> Gratis. Si te sirve: [donar por PayPal](https://paypal.me/carlostapiacl).

Bajá el `.dmg` de la [última versión](https://github.com/carlostapiacl/subele/releases/latest),
abrilo y arrastrá **Subele** a Aplicaciones.

**La primera vez macOS la va a bloquear.** La app está firmada ad-hoc pero **no
notarizada**: notarizar exige una cuenta de Apple Developer de pago (USD 99 al
año). Vas a ver *"Apple no pudo verificar que esté libre de malware"*. Para
destrabarla, una de estas dos:

- **Ajustes del Sistema → Privacidad y seguridad**, bajá hasta el aviso sobre
  Subele y tocá **Abrir igualmente**.
- O en la Terminal:
  ```bash
  xattr -d com.apple.quarantine "/Applications/Subele.app"
  ```

En macOS 15 el viejo truco de Control-clic → Abrir ya no alcanza; hay que pasar
por Ajustes del Sistema.

### Compilar

Si preferís no confiar en un binario sin notarizar —razonable—, son unos
segundos:

```bash
git clone https://github.com/carlostapiacl/subele
cd subele
./build-app.sh
open "Subele.app"
```

`build-app.sh` compila release, corre los tests, genera el ícono, arma el `.app` a
mano (SwiftPM no produce bundles) y lo firma ad-hoc. La firma ad-hoc alcanza para
correrlo en la máquina que lo compiló; distribuirlo pediría un certificado
Developer ID y notarización.

`Tools/make-dmg.sh` arma el `.dmg` descargable, y el workflow `release.yml` lo
publica solo al empujar una etiqueta `v*`.

El ícono se genera por código en `Tools/make-icon.swift`, así que se revisa en
diff como cualquier otro archivo en vez de ser un binario opaco. Dibuja un dial
que pasa del máximo —arco blanco hasta el tope, ámbar siguiendo más allá— con un
parlante al centro. El ámbar es el mismo color que usa el medidor cuando el
limitador trabaja. El de la barra de menú repite la idea en monocromo: **el arco
sigue más allá del tope solo cuando la ganancia pasa de 100%**, así se sabe de un
vistazo si está amplificando. El porcentaje aparece al lado.

## Uso

<p align="center"><img src="docs/screenshot-menu.png" width="300" alt="El menú de Subele"></p>

Aparece un ícono de parlante en la barra de menú. Al abrirlo: el dispositivo de
salida y su formato, un medidor de nivel que se pone naranja mientras el limitador
trabaja, un slider de 50 a 400%, el selector de modo con lo que hace cada uno, y los menús
de latencia, frecuencia de muestreo, ecualizador e idioma.

La ganancia, el modo, el ecualizador, la latencia y el idioma se guardan entre
sesiones. La frecuencia de muestreo no la guarda la app: es del dispositivo, y
macOS ya la recuerda.

Todo lo que cruza entre la interfaz y el hilo de audio —ganancia, modo, bandas
del ecualizador y medidores— pasa por atómicos (`Sources/CAtomics`, porque el
`Atomic` de Swift exige macOS 15).

Un binario, dos caras — el bundle `.app` solo lo envuelve:

```bash
subele              # app de barra de menú
subele --cli        # consola interactiva
subele --cli --buffer 128
subele --help
```

`SUBELE_TRACE=1` traza cada paso del arranque a stderr. Las llamadas a CoreAudio
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
escala, salida idéntica bit a bit entre bloques de 32 y de 1024, el ecualizador
plano sin tocar un bit y cada banda subiendo lo que dice, conteos de canales
de mono a 7.1 (1, 2, 4, 6 y 8), la curva dibujada coincidiendo con un seno filtrado
de verdad, el analizador de espectro ubicando un tono, y NaN o infinito llegando a la entrada sin matar la
cadena.

## Limitaciones conocidas

- **Otro booster con driver lo cuelga.** Si eqMac o Boom 3D está corriendo, es
  dueño de la salida por defecto, así que tapeamos *su* dispositivo virtual, que a
  su vez está pasando audio. `AudioDeviceCreateIOProcIDWithBlock` entonces bloquea
  para siempre sin dar error. Hay que cerrarlo primero.
- **AirPlay, sin confirmar.** Los parlantes AirPlay tienen su propio buffer de
  unos dos segundos y no está probado que el dispositivo agregado los acepte como
  salida (por confirmar). Un Bluetooth sí funciona.
- **El modo Voz sube el piso de ruido**, porque el makeup también se aplica
  cuando no hay señal. Es inherente al modo, no un defecto.
- **No arranca al iniciar sesión.** A propósito: no se instala un elemento de
  arranque sin que lo pidan.

## Estructura

```
Sources/CAtomics/            cargas y guardas atómicas para los parámetros
Sources/BoosterKit/          la parte reutilizable, sin AppKit
  Booster.swift              la versión, única fuente de verdad
  Atomics.swift              Float y UInt32 atómicos sobre CAtomics
  CoreAudio/
    AudioObject.swift        envoltorio tipado de la API de propiedades, errores, traza
    AudioDevices.swift       consultas de dispositivos y observación de la salida
    ProcessTap.swift         vida del tap
    AggregateDevice.swift    vida del dispositivo agregado, tamaño de buffer
  DSP/
    Decibels.swift           conversiones a dB y coeficientes de suavizado
    Compressor.swift         curva de rodilla suave y makeup automático
    Equalizer.swift          5 biquads RBJ, coeficientes recalculados en el hilo de audio
    Limiter.swift            línea de retardo y mínimo deslizante
    BoostProcessor.swift     la cadena
  Analysis/
    SpectrumTap.swift        últimas muestras de la salida, sin locks
    SpectrumAnalyzer.swift   FFT a bandas logarítmicas
  Engine/
    BoostEngine.swift        tap + agregado + IOProc + medición de latencia
Sources/subele/              el ejecutable
  main.swift                 elige el modo según los argumentos
  EqualizerView.swift        el ecualizador gráfico
  MenuBarApp.swift           frente en AppKit
  MenuBarIcon.swift          ícono de la barra, dibujado por código
  LevelMeterView.swift
  ConsoleMode.swift
  Strings.swift              todo el texto visible, tipado, en dos idiomas
Tools/make-icon.swift        genera AppIcon.icns
Tests/BoosterKitTests/
```

`BoosterKit` no depende de AppKit ni sabe que existe una interfaz, así que el
motor se puede embeber en otra cosa.

## Sitio

[carlostapiacl.github.io/subele](https://carlostapiacl.github.io/subele/) — la página del proyecto, en `docs/`.

## Licencia

MIT © Carlos Tapia
