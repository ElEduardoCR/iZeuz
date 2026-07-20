# ZeuzDNC para iOS

Transferencia de programas G-code a maquinas CNC por RS232 desde un iPhone o
iPad. Es el equivalente iOS del ZeuzDNC de la Raspberry Pi: mismo flujo
(carpeta compartida → editor → ENVIAR), misma logica de perfiles de maquina,
pero nativo en Swift + SwiftUI con Liquid Glass.

---

## ⚠️ Lo primero: la cadena OTG no funciona en iOS

**Un iPhone no puede hablar con un adaptador USB-RS232 generico.** La cadena
`iPhone → OTG → USB-A → USB-RS232 → DB9 → DB25` **no funciona**, y no es un
problema de programacion: iOS no expone ninguna API publica para periféricos
USB genericos. No existe `/dev/ttyUSB0`. Los chips FTDI, CH340, PL2303 y
similares son invisibles para el sistema, conectes el cable que conectes.

Esta app resuelve el problema por los dos unicos caminos que iOS permite:

| Camino | Como funciona | Cuando usarlo |
|---|---|---|
| **Puente en red** (recomendado) | El iPhone manda el G-code por WiFi a un puente que lo saca por RS232 | Ya tienes una Raspberry Pi. Cero hardware certificado |
| **Cable MFi** | Cable certificado Redpark directo del iPhone al DB9 | Sin red disponible, o el iPhone tiene que estar junto a la maquina |

El tramo final **DB9 → DB25 sigue siendo solo cableado**: eso no cambia.

La app tiene una capa de transporte intercambiable, asi que el mismo binario
sirve para los dos y para un simulador sin hardware. Cambiar de uno a otro es
elegir otro puerto en la interfaz.

---

## Requisitos

- Xcode 26 o superior, SDK de iOS 26
- iPhone o iPad con iOS 26
- Una carpeta compartida por SMB en la red (la misma que ya usas desde
  Windows o Mac)
- Un puente serial **o** un cable Redpark (ver abajo)

---

## Puesta en marcha

### 1. Abrir el proyecto

```bash
open ZeuzDNC.xcodeproj
```

Xcode resuelve solo la dependencia de [AMSMB2](https://github.com/amosavian/AMSMB2)
(cliente SMB2/3). En **Signing & Capabilities** elige tu equipo de desarrollo
y cambia el bundle id si `com.zeuz.dnc` ya esta tomado.

> **Licencia:** AMSMB2 es LGPL v2.1. Para uso interno en el taller no hay
> problema. Si algun dia publicas en el App Store, tiene que ir enlazada
> dinamicamente (Embed & Sign, que es el default de SPM).

### 2. Configurar la carpeta compartida

En la app: **⚙︎ Ajustes → Carpeta compartida**

| Campo | Ejemplo |
|---|---|
| Servidor | `192.168.1.10` |
| Recurso compartido | `cnc-programs` |
| Subcarpeta | (vacio, o `torno/2026`) |
| Usuario / Contrasena | las del share |

La contrasena se guarda en el llavero del iPhone, nunca en texto plano.

Al guardar un programa desde Windows o Mac en esa carpeta, **aparece solo en
el iPhone en unos segundos** — la app sondea la carpeta que estas viendo y
recarga solo si cambio.

### 3. Configurar el puente serial

#### Opcion A — Raspberry Pi (la que ya tienes)

```bash
sudo apt update && sudo apt install -y ser2net
sudo cp Tools/bridge/ser2net.yaml /etc/ser2net.yaml
sudo systemctl enable --now ser2net
```

`ser2net` soporta RFC 2217, asi que la app le dice el baudrate, paridad y
bits en cada envio segun el perfil de la maquina. No hay que reconfigurar
nada al cambiar de CNC.

**Con un hub de varios adaptadores**, descomenta los puertos extra en
`ser2net.yaml` y **anclalos con nombres estables**:

```bash
sudo cp Tools/bridge/99-cnc-serial.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

> Esto importa mas de lo que parece: sin anclar, `/dev/ttyUSB0` y `ttyUSB1`
> se pueden intercambiar al reiniciar la Pi, y el programa del torno acabaria
> en la fresadora sin ningun aviso. El archivo de reglas explica como sacar
> el numero de serie de cada adaptador.

#### Opcion B — servidor serial comercial

Moxa NPort, USR-TCP232 y similares funcionan directo. Suelen exponer un
puerto TCP por cada puerto fisico (4001, 4002…). Si soportan RFC 2217,
enciendelo en la app; si no, deja apagada esa opcion y configura el baudrate
en el propio equipo.

#### Opcion C — cable MFi (sin red)

Cables certificados **Redpark**: `C4-DB9V` (iPhone USB-C) o `L2-DB9V3`
(Lightning). Es el unico tipo de cable que iOS acepta para RS232.

Tres cosas que hay que saber antes de comprarlo:

1. La cadena de protocolo del cable debe estar en `ZeuzDNC-Info.plist` bajo
   `UISupportedExternalAccessoryProtocols` **y** coincidir con la del puerto
   en la app. Si no coinciden, iOS no abre la sesion.
2. **La API publica de iOS no permite fijar baudrate ni paridad** — eso lo
   hace el SDK de Redpark, que va bajo licencia. Sin ese SDK el cable usa su
   configuracion por defecto. El punto de integracion esta marcado en
   `MFiSerialTransport.applyLineConfiguration(_:)`.
3. Apple **no permite publicar en el App Store** apps hechas con el SDK de
   Redpark. Se instalan con tu cuenta de desarrollador o por Apple Business
   Manager. Para una herramienta interna de taller eso alcanza.

### 4. Dar de alta puertos y maquinas

**Ajustes → Puertos → Puerto nuevo.** Cada puerto lleva el nombre que
quieras (*Torno chico*, *Fresadora del fondo*). Para un hub, usa **Puente con
hub** y los crea todos de golpe.

**Ajustes → Maquinas.** Vienen Fanuc (4800 7E2, XON/XOFF, CR) y Fadal
(9600 8N1, XON/XOFF, CRLF) como referencia.

> ⚠️ Esos valores son **tipicos, no verificados para tu maquina**. Confirmalos
> contra el manual de cada control antes de produccion.

### 5. Probar sin hardware

Crea un puerto de tipo **Simulador**. Reproduce el envio completo respetando
el tiempo real que tardaria a ese baudrate — sirve para ver la barra de
progreso, la cancelacion y los estados sin tener el puente a la mano.

---

## Como se usa

1. **Programas** — explorador de la carpeta compartida, con subcarpetas,
   breadcrumb y busqueda recursiva por nombre. Tocar un programa lo
   selecciona (sin salir de la lista); los gestos hacen el resto:

   | Gesto | Accion |
   |---|---|
   | Deslizar a la **derecha** | **Enviar** — abre la confirmacion |
   | Deslizar a la **izquierda** | **Editar** — abre el editor |
   | Deslizar a la izquierda y seguir | **Eliminar** (segundo boton, nunca con deslizamiento completo) |

2. **Editor** — editar, guardar, buscar y reemplazar, con **coloreado de
   G-code al estilo CIMCO**: G en azul, M en rojo, ejes en verde, arcos en
   turquesa, avance en naranja, husillo en morado, herramienta en dorado y
   comentarios en gris cursiva. El menu **···** tiene la leyenda completa.
   Los archivos de mas de 2 MB se abren en solo lectura.

3. **Enviar** — barra inferior **siempre visible** con maquina, puerto y
   **ENVIAR**. No se oculta al navegar: que maquina y que puerto estan
   elegidos es informacion que hace falta a la vista todo el tiempo. Cuando
   falta algo, el boton se ve pero queda inaccesible y debajo dice exactamente
   que falta.

Igual que en la Pi, **enviar siempre es manual y con confirmacion**. La app
nunca transmite sola porque aparecio un archivo. El boton solo se habilita
cuando hay programa abierto **sin cambios pendientes**, maquina elegida y
puerto elegido — si falta algo, la barra dice exactamente que.

---

## Arquitectura

```
ZeuzDNC/
  ZeuzDNCApp.swift              AppModel: une las piezas y decide si se puede enviar
  Models/
    Machine.swift               Perfil serial (baudrate, bits, paridad, flujo, terminador)
    SerialEndpoint.swift        Puerto con nombre libre (red / MFi / simulador)
    ProgramEntry.swift          Archivos, carpetas y breadcrumb
    TransferState.swift         Estado y eventos de la transferencia
  Services/
    GCodeSender.swift           Payload, troceado, progreso, cancelacion
    Transport/
      SerialTransport.swift     El protocolo que abstrae "por donde salen los bytes"
      NetworkBridgeTransport.swift  TCP + RFC 2217 + XON/XOFF
      MFiSerialTransport.swift  ExternalAccessory (cables Redpark)
      MockTransport.swift       Simulador a velocidad real
      TransportFactory.swift
    SMB/
      SMBClient.swift           Cliente SMB2/3 sobre AMSMB2
      SMBPath.swift             Rutas puras: bloquea el path traversal
      ProgramStore.swift        Navegacion, editor y refresco automatico
      SMBSettings.swift
    Stores/                     Persistencia de maquinas, puertos y llavero
  Views/                        SwiftUI con Liquid Glass
    RootView.swift              Lista + barra de envio anclada abajo
    ProgramBrowserView.swift    Explorador, con los gestos de enviar/editar
    EditorView.swift            Editor, buscar y reemplazar
    Components/
      GCodeHighlighter.swift    Colores y tokenizado del G-code
      GCodeEditor.swift         UITextView con coloreado en vivo + leyenda
Tools/
  verify.sh                     Pruebas del nucleo de envio
  bridge/                       Configuracion del puente para la Pi
```

### Decisiones que vale la pena conocer

**El vaciado antes de cerrar.** Cuando `send()` de TCP retorna, los bytes solo
llegaron *al puente*: todavia tienen que salir por la linea serial a 4800 o
9600 baud. Si cerraramos ahi, el puente descarta lo que le queda en el buffer
y la maquina recibe el programa **incompleto**. Por eso `drain()` calcula
cuanto tarda fisicamente esa cantidad de bytes a ese baudrate y espera la
diferencia. Es el mismo problema que en la Pi resolvia `out_waiting`.

**El terminador se aplica solo al enviar.** Convertir a CR o CRLF pasa sobre
el contenido en memoria; **el archivo en la carpeta compartida no se toca**.
Un programa que llega de Windows con CRLF y se manda a un Fanuc en CR no
duplica el retorno de carro.

**latin-1 en todo el camino.** Mapea 1 a 1 cada byte, asi que nunca falla al
leer G-code/ISO ni altera el contenido.

**Control de flujo.** Con XON/XOFF la app escucha la linea de vuelta y frena
antes de cada bloque. En goteo no hay limite de tiempo (la maquina puede
tardar minutos en un movimiento largo); en modo punch hay una red de
seguridad de 120 s.

**Las rutas nunca se salen del share.** `SMBPath.sanitize` descarta `..` y
normaliza las barras de Windows, igual que `resolve_path` en la Pi.

---

## Verificacion

```bash
./Tools/verify.sh
```

Levanta un puente serial falso y ejerce el nucleo real de envio:

- la conversion de terminador (CR / CRLF / LF), incluido el caso de un
  archivo que ya venia de Windows con CRLF
- el calculo de bits por byte y tiempo de linea (Fanuc 7E2 = 11 bits)
- **un envio real por TCP, comprobando byte a byte lo que llega al otro lado**
- que un XOFF de la maquina **frene de verdad** el envio, y que las 400 lineas
  lleguen intactas tras el XON
- que un puente apagado de un error entendible en vez de colgarse
- que `..` no pueda salirse de la carpeta compartida

---

## Diferencias con la version de la Raspberry Pi

| | Raspberry Pi | iOS |
|---|---|---|
| Salida serial | `pyserial` sobre `/dev/ttyUSB0` | Puente en red o cable MFi |
| Deteccion de puertos | Automatica por udev | Alta manual, con nombre libre |
| Cambios en la carpeta | `watchdog` (instantaneo) | Sondeo cada 4 s |
| Acceso a los programas | Disco local montado por Samba | Cliente SMB2/3 nativo |
| Perfiles de maquina | `config/machines.json` | En la app, con importador del JSON de la Pi |

Los perfiles de la Pi se pueden importar tal cual: `MachineStore.importFromPi(json:)`
lee el mismo `config/machines.json` sin tocarlo.

---

## Problemas frecuentes

**"No se pudo conectar" al puente.** Comprueba que ser2net corre
(`systemctl status ser2net`) y que el iPhone esta en la misma red. La primera
vez iOS pide permiso de red local: si lo negaste, actívalo en Ajustes de iOS →
ZeuzDNC → Red local.

**El puente rechazo la configuracion (RFC 2217).** El equipo no lo soporta.
Apaga esa opcion en el puerto y configura el baudrate directamente en el puente.

**La maquina recibe basura.** Casi siempre es que el baudrate o la paridad no
coinciden con el control. Verifica el perfil contra el manual. Si es correcto,
prueba invirtiendo DTR/RTS: muchas configuraciones de PC que funcionan los
tienen apagados.

**La maquina no recibe nada.** Ponla en modo recepcion *antes* de tocar
ENVIAR. Revisa tambien que el cable DB9→DB25 tenga el cruce correcto de
TX/RX para tu control.

**El cable MFi no aparece.** Solo funcionan cables certificados. Verifica que
la cadena de protocolo del puerto coincida con la de `ZeuzDNC-Info.plist`.
En **Puertos** se listan los cables que iOS detecta ahora mismo, con sus
protocolos reales — es la forma rapida de saber cual poner.
