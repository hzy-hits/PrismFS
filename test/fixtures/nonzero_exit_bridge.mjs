let buffer = Buffer.alloc(0);

function send(value, afterWrite) {
  const payload = Buffer.from(JSON.stringify(value));
  const frame = Buffer.alloc(payload.length + 4);
  frame.writeUInt32BE(payload.length);
  payload.copy(frame, 4);
  process.stdout.write(frame, afterWrite);
}

process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (buffer.length >= 4) {
    const size = buffer.readUInt32BE(0);
    if (buffer.length < size + 4) return;
    const request = JSON.parse(buffer.subarray(4, size + 4).toString("utf8"));
    buffer = buffer.subarray(size + 4);
    if (request.op === "shutdown") {
      send({ id: request.id, ok: true, result: null }, () => process.exit(7));
    }
  }
});
