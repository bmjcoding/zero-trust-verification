// In-page developer console widget for the game HUD: lines render into a
// DOM panel, never to the browser console.
// MUST-NOT-FLAG N7: game_console.log/info is not console.log/info - the
// MUST-NOT-FLAG N7: underscore defeats the \b anchor in LOGGING_RE, and the
// MUST-NOT-FLAG N7: sprintf helper defeats the anchored print token. Any
// MUST-NOT-FLAG N7: widgets.ts line in stdout_logging.txt is a precision
// MUST-NOT-FLAG N7: failure. Nothing in this file is a defect.

export interface ConsoleLine {
  level: string;
  text: string;
}

export function sprintf(template: string, ...args: unknown[]): string {
  let i = 0;
  return template.replace(/%s/g, () => String(args[i++] ?? ""));
}

export class GameConsoleWidget {
  private lines: ConsoleLine[] = [];

  log(text: string): void {
    this.lines.push({ level: "log", text });
  }

  info(text: string): void {
    this.lines.push({ level: "info", text });
  }

  render(): string {
    return this.lines.map((l) => `[${l.level}] ${l.text}`).join("\n");
  }
}

export const game_console = new GameConsoleWidget();

export function announceUnlock(item: string): void {
  game_console.log(sprintf("unlocked %s", item));
}

export function announceScore(points: number): void {
  game_console.info(sprintf("score +%s", points));
}
