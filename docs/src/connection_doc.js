// connection_doc.js OUT.docx DIAGRAM.png -- ASpectrum wiring document (US Letter, 1" margins)
const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType, ShadingType,
  HeadingLevel, AlignmentType, LevelFormat, BorderStyle, ImageRun, Footer, PageNumber,
} = require("docx");

const W = 9360;
const FONT = "Calibri";
const border = { style: BorderStyle.SINGLE, size: 4, color: "A6A6A6" };
const borders = { top: border, bottom: border, left: border, right: border };

function runs(text, size = 20) {
  return text.split(/(\*\*[^*]+\*\*|`[^`]+`)/).filter(Boolean).map(t => {
    if (t.startsWith("**")) return new TextRun({ text: t.slice(2, -2), bold: true, font: FONT, size });
    if (t.startsWith("`"))  return new TextRun({ text: t.slice(1, -1), font: "Consolas", size: size - 2 });
    return new TextRun({ text: t, font: FONT, size });
  });
}
function cell(text, width, head = false, fill) {
  const lines = Array.isArray(text) ? text : [text];
  return new TableCell({
    width: { size: width, type: WidthType.DXA }, borders,
    shading: head ? { type: ShadingType.CLEAR, color: "auto", fill: "1F3864" }
           : fill ? { type: ShadingType.CLEAR, color: "auto", fill } : undefined,
    margins: { top: 40, bottom: 40, left: 80, right: 80 },
    children: lines.map(l => new Paragraph({
      children: head ? [new TextRun({ text: l, bold: true, color: "FFFFFF", font: FONT, size: 18 })] : runs(l, 18),
    })),
  });
}
function table(widths, header, rows, fill) {
  const sum = widths.reduce((a, b) => a + b, 0);
  if (sum !== W) throw new Error("table widths " + sum);
  return new Table({
    width: { size: W, type: WidthType.DXA }, columnWidths: widths,
    rows: [new TableRow({ tableHeader: true, children: header.map((h, i) => cell(h, widths[i], true)) }),
           ...rows.map(r => new TableRow({ cantSplit: true, children: r.map((c, i) => cell(c, widths[i], false, fill)) }))],
  });
}
const h1 = t => new Paragraph({ heading: HeadingLevel.HEADING_1, spacing: { before: 300, after: 120 }, children: [new TextRun({ text: t, font: FONT })] });
const p  = t => new Paragraph({ spacing: { after: 110 }, children: runs(t, 21) });
const b  = t => new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { after: 50 }, children: runs(t, 21) });
const n  = t => new Paragraph({ numbering: { reference: "check", level: 0 }, spacing: { after: 50 }, children: runs(t, 21) });
const gap = () => new Paragraph({ spacing: { after: 80 }, children: [] });
const caption = t => new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 160 }, children: [new TextRun({ text: t, italics: true, size: 18, font: FONT, color: "595959" })] });

const img = fs.readFileSync(process.argv[3]);
const PINW = [1000, 1000, 2300, 1900, 900, 2260];      // header pin, FPGA pin, other side, signal, dir, notes
const PINH = ["Header pin", "FPGA pin", "Goes to", "Signal", "Dir", "Notes"];

const C = [];
C.push(new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "ASpectrum — connections", bold: true, size: 44, font: FONT, color: "1F3864" })] }));
C.push(new Paragraph({ spacing: { after: 240 }, children: [new TextRun({ text: "How the QMTECH Cyclone IV core board, the QM_Atrix adapter, the ESP32 system controller and the microSD card are wired (state of 14 October 2026)", size: 21, font: FONT, color: "595959" })] }));

C.push(h1("1. Overview"));
C.push(new Paragraph({ alignment: AlignmentType.CENTER, children: [new ImageRun({ type: "png", data: img, transformation: { width: 624, height: 340 } })] }));
C.push(caption("Figure 1. What plugs into which header of the core board."));
C.push(table([2400, 2600, 4360], ["Part", "Connected to", "Carries"], [
  ["QM_Atrix adapter, J2", "U8, plugged in directly (J2.1 on U8.64)", "VGA, USB keyboard module, 5 V for the adapter"],
  ["QM_Atrix adapter, J1", "U7, by wires", "AY and beeper audio to the amplifier, Kempston joystick, ground"],
  ["ESP32-WROOM-32 DevKit", "U7.7-11, U7.17-21 + ground, by wires", "SPI link for the tape loader, sound as I2S, UART for the F3 Bluetooth menu"],
  ["Adafruit MicroSD BFF", "the ESP32, by wires", "SD card (SPI) for the tape loader, 3.3 V"],
  ["Bluetooth headphones / speaker", "the ESP32, by radio (A2DP)", "the Spectrum's sound"],
]));
C.push(gap());
C.push(p("All FPGA pins are 3.3 V (LVTTL) and **not 5 V tolerant**. Every signal on the headers is 3.3 V: the adapter makes its own 3.3 V for its pull-ups, the keyboard module's UART is 3.3 V, and the ESP32 is a 3.3 V part."));

C.push(h1("2. The core board headers"));
C.push(p("U7 is the left header and U8 the right one (32 x 2 pins each). On both: pins 1/2 ground, 3/4 3.3 V, 61/62 ground, 63/64 VIN (5 V). The numbering was read from the QMTECH schematic: **check 1/2, 3/4, 61/62 and 63/64 with a meter** before connecting anything new. Full header map: docs/BOARD_PINOUT.md."));
C.push(table([2400, 6960], ["On-board", "Pin / use"], [
  ["50 MHz oscillator", "T2"],
  ["KEY0 (button farther from the long edge)", "W13: reset of everything"],
  ["KEY1", "Y13: not used"],
  ["LED", "E4: on = turbo; fast blink = no ROMs in the flash (program the .jic)"],
  ["SDRAM, configuration flash", "on the board, nothing to wire"],
]));

C.push(h1("3. Adapter J2 on U8"));
C.push(p("J2 is plugged straight into U8 with J2 pin 1 on U8 pin 64 (so J2 pin k sits on U8 pin 65 - k). J2 pin 2 is cut off on the adapter, because it would sit on VIN. U8 pins not listed are not connected on the adapter."));
C.push(table(PINW, PINH, [
  ["U8.64", "-", "J2.1 5V0", "5 V", "power", "feeds the adapter: its 3.3 V regulator, keyboard module, audio amplifier"],
  ["U8.61, 62", "-", "J2.4, J2.3", "GND", "", "VGA ground return"],
  ["U8.59", "M20", "BL", "VGA_B_LOW", "out", ""],
  ["U8.57", "N20", "BH", "VGA_B", "out", ""],
  ["U8.55", "B22", "GL", "VGA_G_LOW", "out", ""],
  ["U8.53", "C22", "GH", "VGA_G", "out", ""],
  ["U8.51", "D22", "RL", "VGA_R_LOW", "out", ""],
  ["U8.49", "E22", "RH", "VGA_R", "out", ""],
  ["U8.47", "F22", "HS", "VGA_HSYNC", "out", ""],
  ["U8.45", "H22", "VS", "VGA_VSYNC", "out", ""],
  ["U8.19, 17", "AA19, AA18", "keyboard module J5.2 / J5.3", "KBD_A, KBD_B", "in", "UART 115,200 from the USB keyboard module (both inputs)"],
  ["U8.16, 15", "AB17, AA17", "J2.49, J2.50 = GND", "GND_TIE", "in", "grounded by the adapter: never drive"],
]));

C.push(p("U8.1-14 (above the adapter) are not used. U8.5 and U8.6 are clock-only inputs of the FPGA: never use them for anything else."));

C.push(h1("4. Adapter J1, wired to U7"));
C.push(p("J1 hangs outside the core board; its signals go to U7 by wires. Do **not** wire J1.1 (5 V) or J1.2 (3.3 V): the adapter is powered through J2."));
C.push(table(PINW, PINH, [
  ["U7.1", "-", "J1.3 GND", "GND", "", "ground wire in the bundle"],
  ["U7.15", "J1", "J1.17 AY", "AUDIO_AY", "out", "sigma-delta; 68 Ω + 100 nF filter on the adapter"],
  ["U7.16", "J2", "J1.19 Beeper", "AUDIO_BEEPER", "out", "port FE bit 4"],
  ["U7.23", "C1", "J1.15 Up", "JOY_UP_N", "in", "3.3 kΩ pull-ups on the adapter, active low"],
  ["U7.24", "C2", "J1.11 Down", "JOY_DOWN_N", "in", ""],
  ["U7.25", "B1", "J1.9 Left", "JOY_LEFT_N", "in", ""],
  ["U7.26", "B2", "J1.7 Right", "JOY_RIGHT_N", "in", ""],
  ["U7.27", "B3", "J1.13 Fire", "JOY_FIRE_N", "in", ""],
]));
C.push(gap());
C.push(p("J1.5 (the adapter's 50/60 switch) is not connected: the video mode is chosen with F8."));

C.push(h1("5. ESP32 system controller and microSD card"));
C.push(p("A 30-pin ESP32-WROOM-32 DevKit (CP2102, USB-C) with the sketch ASpectrum/esp32/esp32.ino. It owns the microSD card, runs the tape loader and the Bluetooth audio, and talks to the FPGA over an SPI link with an interrupt line, an I2S sound input and a UART. The ESP32 drives the link and I2S clocks. ESP32 pins are given by their DOIT 30-pin board labels."));
const ESPW = [1500, 1700, 1300, 1500, 1000, 2360];
C.push(table(ESPW, ["ESP32 board pin", "Signal", "Dir", "FPGA board pin", "FPGA pin", "Notes"], [
  ["D35", "ESP_MISO", "FPGA → ESP32", "U7.7", "R1", "link data to the ESP32; D35 is input-only"],
  ["D34", "ESP_IRQ", "FPGA → ESP32", "U7.8", "R2", "interrupt, active high; D34 is input-only"],
  ["D14", "ESP_SCK", "ESP32 → FPGA", "U7.9", "P1", "link clock, 8 MHz; FPGA pull-up"],
  ["D13", "ESP_MOSI", "ESP32 → FPGA", "U7.10", "P2", "link data to the FPGA; FPGA pull-up"],
  ["D33", "ESP_CS_N", "ESP32 → FPGA", "U7.11", "N1", "link select; FPGA pull-up (idle while the ESP32 boots)"],
  ["D26", "BT_BCLK", "ESP32 → FPGA", "U7.17", "H1", "I2S bit clock, 1.4112 MHz; FPGA pull-up"],
  ["D25", "BT_LRCK", "ESP32 → FPGA", "U7.18", "H2", "I2S word select, 44.1 kHz; FPGA pull-up"],
  ["D22", "BT_DATA", "FPGA → ESP32", "U7.19", "F1", "sound, 16-bit; ESP32 pull-down"],
  ["RX2 (GPIO16)", "BT_TX", "FPGA → ESP32", "U7.20", "F2", "F3 menu commands, 115,200 baud"],
  ["TX2 (GPIO17)", "BT_RX", "ESP32 → FPGA", "U7.21", "E1", "answers and events; FPGA pull-up"],
  ["GND", "GND", "", "U7.1 / U7.2", "-", "required; run it alongside the signal wires"],
], "FDF0E2"));
C.push(gap());
C.push(p("The microSD card (Adafruit MicroSD BFF) is wired to the ESP32 only. The BFF's jumpers are unchanged (CS = its TX pin); keep 10 µF + 100 nF across 3.3 V and ground at the BFF; its other pins stay unconnected."));
C.push(table([2000, 2400, 1700, 3260], ["ESP32 board pin", "BFF pin", "Signal", "Notes"], [
  ["D18", "JP3.2 SCK", "SD SCK", "ESP32 VSPI, 20 MHz"],
  ["D19", "JP3.3 MISO", "SD MISO", "ESP32 pull-up; a 10k-47k resistor to 3.3 V is better"],
  ["D23", "JP3.4 MOSI", "SD MOSI", ""],
  ["D5", "JP1.7 TX", "SD CS", ""],
  ["3V3", "JP3.5 3.3V", "3.3 V", "from the ESP32 board"],
  ["GND", "JP3.6 GND", "GND", ""],
], "E2EFDA"));
C.push(gap());
C.push(b("**Power:** from the ESP32's own USB-C port (a phone charger is fine), or 5 V from U7.63/64 into the ESP32's VIN pin. Never 5 V on any signal pin."));
C.push(b("**Direction check:** the FPGA's TX goes to the ESP32's RX2, and the ESP32's TX2 to the FPGA's RX; I2S data and link MISO go from the FPGA to the ESP32."));
C.push(b("**Either side unplugged** is safe: pull-ups and a pull-down keep the lines quiet; the Spectrum boots and runs without the ESP32 (no SD card, no Bluetooth)."));
C.push(b("**USB on the ESP32** is for programming and debugging (a terminal at 115,200 baud shows the loader's messages and takes the Bluetooth commands). Pairing is done from ASpectrum: **F3** opens the Bluetooth menu."));
C.push(b("Pins avoided on the ESP32 on purpose: GPIO12 (the FPGA's pull-ups would select 1.8 V flash at boot), GPIO2 and GPIO15 (boot strapping), GPIO6-11 (flash)."));
C.push(b("Keep the wires short (under ~20 cm). **Wiring test:** tests/Test_wires/ checks every wire and the SD card and reports on the ESP32's USB port."));

C.push(h1("6. Power"));
C.push(table([2600, 6760], ["What", "From"], [
  ["Core board", "its own power input (USB or 5 V); everything else on the FPGA side is fed from it"],
  ["QM_Atrix adapter", "5 V from U8.64 through J2.1; the adapter makes its own 3.3 V"],
  ["USB keyboard module", "5 V via the adapter (USB power only; its UART is 3.3 V)"],
  ["microSD BFF", "3.3 V from the ESP32 board"],
  ["ESP32 DevKit", "its own USB-C, or 5 V from U7.63/64 into VIN"],
]));

C.push(h1("7. Before switching on"));
C.push(n("Meter check of the header power pins (section 2) after any change in the wiring."));
C.push(n("No wire from J1.1 / J1.2 or any 5 V pin to a signal pin; U8.15/16 (grounded by the adapter) are never outputs."));
C.push(n("The configuration flash holds an ASpectrum image (or nothing): a demo image could drive header pins against the adapter."));
C.push(n("Ground wires present on U7 (J1 bundle and ESP32)."));
C.push(n("Support the adapter's J1 side with a spacer, so the cables do not lever on U8."));

const doc = new Document({
  creator: "AlteraZX", title: "ASpectrum connections",
  styles: {
    default: { document: { run: { font: FONT, size: 21 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 28, bold: true, color: "1F3864", font: FONT }, paragraph: { outlineLevel: 0 } },
    ],
  },
  numbering: { config: [
    { reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 540, hanging: 270 } } } }] },
    { reference: "check", levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 540, hanging: 300 } } } }] },
  ] },
  sections: [{
    properties: { page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, bottom: 1440, left: 1440, right: 1440 } } },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [
      new TextRun({ text: "ASpectrum connections  -  page ", size: 16, color: "808080", font: FONT }),
      new TextRun({ children: [PageNumber.CURRENT], size: 16, color: "808080", font: FONT })] })] }) },
    children: C,
  }],
});
Packer.toBuffer(doc).then(buf => { fs.writeFileSync(process.argv[2], buf); console.log("written", process.argv[2], buf.length); });
