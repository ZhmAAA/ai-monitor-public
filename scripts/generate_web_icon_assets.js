#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");
const zlib = require("node:zlib");

const rootDir = path.resolve(__dirname, "..");
const outDir = path.join(rootDir, "apps/desktop-macos/Assets/WebIcons");

function crc32(buffer) {
  if (!crc32.table) {
    crc32.table = new Uint32Array(256);
    for (let i = 0; i < 256; i += 1) {
      let c = i;
      for (let bit = 0; bit < 8; bit += 1) {
        c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      }
      crc32.table[i] = c >>> 0;
    }
  }

  let c = 0xffffffff;
  for (const byte of buffer) {
    c = crc32.table[(c ^ byte) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const typeBuffer = Buffer.from(type, "ascii");
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([typeBuffer, data])), 0);
  return Buffer.concat([length, typeBuffer, data, checksum]);
}

function encodePng(width, height, pixels) {
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);

  for (let y = 0; y < height; y += 1) {
    raw[y * (stride + 1)] = 0;
    pixels.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function rgba(hex) {
  const value = hex.replace("#", "");
  return [
    parseInt(value.slice(0, 2), 16),
    parseInt(value.slice(2, 4), 16),
    parseInt(value.slice(4, 6), 16),
    255,
  ];
}

function writeIcon(fileName, background, foreground, draw) {
  const width = 32;
  const height = 32;
  const pixels = Buffer.alloc(width * height * 4);
  const bg = rgba(background);
  const fg = rgba(foreground);
  const radius = 7;

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const clampX = x < radius ? radius : x >= width - radius ? width - radius - 1 : x;
      const clampY = y < radius ? radius : y >= height - radius ? height - radius - 1 : y;
      const dx = x - clampX;
      const dy = y - clampY;
      if (dx * dx + dy * dy > radius * radius) continue;

      const index = (y * width + x) * 4;
      pixels[index] = bg[0];
      pixels[index + 1] = bg[1];
      pixels[index + 2] = bg[2];
      pixels[index + 3] = bg[3];
    }
  }

  function rect(x, y, w, h, color = fg) {
    for (let yy = y; yy < y + h; yy += 1) {
      for (let xx = x; xx < x + w; xx += 1) {
        if (xx < 0 || yy < 0 || xx >= width || yy >= height) continue;
        const index = (yy * width + xx) * 4;
        if (pixels[index + 3] === 0) continue;
        pixels[index] = color[0];
        pixels[index + 1] = color[1];
        pixels[index + 2] = color[2];
        pixels[index + 3] = color[3];
      }
    }
  }

  draw({ rect });
  fs.writeFileSync(path.join(outDir, fileName), encodePng(width, height, pixels));
}

writeIcon("perplexity-web.png", "#0b5f68", "#ffffff", ({ rect }) => {
  rect(9, 7, 4, 19);
  rect(13, 7, 8, 4);
  rect(21, 9, 3, 7);
  rect(13, 15, 8, 4);
  rect(21, 18, 3, 4);
  rect(13, 22, 9, 4);
});

writeIcon("github-web.png", "#24292f", "#ffffff", ({ rect }) => {
  rect(8, 8, 4, 19);
  rect(20, 8, 4, 19);
  rect(12, 14, 8, 4);
  rect(8, 7, 16, 3);
  rect(8, 24, 16, 3);
});

console.log("Generated web icon assets");
