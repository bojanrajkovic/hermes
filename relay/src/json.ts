/** Parses JSON text, or returns undefined when the text isn't JSON. */
export function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}
