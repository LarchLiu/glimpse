import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const BINARY = join(__dirname, 'glimpse');

class GlimpseWindow extends EventEmitter {
  #proc;
  #closed = false;
  #pendingHTML = null;

  constructor(proc, initialHTML) {
    super();
    this.#proc = proc;
    this.#pendingHTML = initialHTML;

    proc.stdin.on('error', () => {});

    const rl = createInterface({ input: proc.stdout, crlfDelay: Infinity });
    rl.on('line', (line) => {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.emit('error', new Error(`Malformed protocol line: ${line}`));
        return;
      }

      switch (message.type) {
        case 'ready':
          if (this.#pendingHTML !== null) {
            this.setHTML(this.#pendingHTML);
            this.#pendingHTML = null;
          } else {
            this.emit('ready');
          }
          break;
        case 'message':
          this.emit('message', message.data);
          break;
        case 'closed':
          if (!this.#closed) {
            this.#closed = true;
            this.emit('closed');
          }
          break;
        default:
          break;
      }
    });

    proc.on('error', (error) => this.emit('error', error));
    proc.on('exit', () => {
      if (!this.#closed) {
        this.#closed = true;
        this.emit('closed');
      }
    });
  }

  #write(payload) {
    if (this.#closed) return;
    this.#proc.stdin.write(JSON.stringify(payload) + '\n');
  }

  setHTML(html) {
    this.#write({ type: 'html', html: Buffer.from(html).toString('base64') });
  }

  close() {
    this.#write({ type: 'close' });
  }
}

export function open(html, options = {}) {
  if (!existsSync(BINARY)) {
    throw new Error("Glimpse host binary not found. Run 'npm install @cloudgeek/glimpse' to build it.");
  }

  const args = [];
  if (options.width != null) args.push('--width', String(options.width));
  if (options.height != null) args.push('--height', String(options.height));
  if (options.title != null) args.push('--title', options.title);
  if (options.autoClose) args.push('--auto-close');
  if (options.resizable) args.push('--resizable');

  const proc = spawn(BINARY, args, { stdio: ['pipe', 'pipe', 'inherit'] });
  return new GlimpseWindow(proc, html);
}

export function prompt(html, options = {}) {
  return new Promise((resolve, reject) => {
    const win = open(html, { ...options, autoClose: true });
    let resolved = false;

    const timer = options.timeout
      ? setTimeout(() => {
          if (!resolved) {
            resolved = true;
            win.close();
            reject(new Error('Prompt timed out'));
          }
        }, options.timeout)
      : null;

    win.once('message', (data) => {
      if (!resolved) {
        resolved = true;
        if (timer) clearTimeout(timer);
        win.close();
        resolve(data);
      }
    });

    win.once('closed', () => {
      if (timer) clearTimeout(timer);
      if (!resolved) {
        resolved = true;
        resolve(null);
      }
    });

    win.once('error', (error) => {
      if (timer) clearTimeout(timer);
      if (!resolved) {
        resolved = true;
        reject(error);
      }
    });
  });
}
