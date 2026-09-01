export interface InstantAnswer {
  title: string;
  subtitle: string;
}

interface Unit {
  category: string;
  toBase: number;
  label: string;
}

const units = new Map<string, Unit>();

function addUnit(names: string[], category: string, toBase: number, label: string): void {
  for (const name of names) units.set(name, { category, toBase, label });
}

addUnit(["mm", "millimeter", "millimeters"], "length", 0.001, "mm");
addUnit(["cm", "centimeter", "centimeters"], "length", 0.01, "cm");
addUnit(["m", "meter", "meters", "metre", "metres"], "length", 1, "m");
addUnit(["km", "kilometer", "kilometers"], "length", 1000, "km");
addUnit(["in", "inch", "inches"], "length", 0.0254, "in");
addUnit(["ft", "foot", "feet"], "length", 0.3048, "ft");
addUnit(["yd", "yard", "yards"], "length", 0.9144, "yd");
addUnit(["mi", "mile", "miles"], "length", 1609.344, "mi");
addUnit(["g", "gram", "grams"], "mass", 0.001, "g");
addUnit(["kg", "kilogram", "kilograms", "kilo", "kilos"], "mass", 1, "kg");
addUnit(["lb", "lbs", "pound", "pounds"], "mass", 0.45359237, "lb");
addUnit(["oz", "ounce", "ounces"], "mass", 0.028349523, "oz");
addUnit(["ml", "milliliter", "milliliters"], "volume", 0.001, "ml");
addUnit(["l", "liter", "liters", "litre", "litres"], "volume", 1, "L");
addUnit(["gal", "gallon", "gallons"], "volume", 3.785411784, "gal");
addUnit(["cup", "cups"], "volume", 0.2365882365, "cups");
addUnit(["floz"], "volume", 0.0295735296, "fl oz");
addUnit(["kb"], "data", 1, "KB");
addUnit(["mb"], "data", 1024, "MB");
addUnit(["gb"], "data", 1_048_576, "GB");
addUnit(["tb"], "data", 1_073_741_824, "TB");
addUnit(["s", "sec", "second", "seconds"], "time", 1, "s");
addUnit(["min", "minute", "minutes"], "time", 60, "min");
addUnit(["h", "hr", "hour", "hours"], "time", 3600, "hr");
addUnit(["d", "day", "days"], "time", 86400, "days");

function format(value: number): string {
  return new Intl.NumberFormat(undefined, {
    maximumFractionDigits: Math.abs(value) < 1 ? 6 : 4,
  }).format(value);
}

class ArithmeticParser {
  private index = 0;

  constructor(private readonly input: string) {}

  parse(): number | null {
    try {
      const value = this.expression();
      this.skipSpaces();
      return this.index === this.input.length && Number.isFinite(value) ? value : null;
    } catch {
      return null;
    }
  }

  private expression(): number {
    let value = this.term();
    while (true) {
      this.skipSpaces();
      const operator = this.input[this.index];
      if (operator !== "+" && operator !== "-") return value;
      this.index += 1;
      const right = this.term();
      value = operator === "+" ? value + right : value - right;
    }
  }

  private term(): number {
    let value = this.factor();
    while (true) {
      this.skipSpaces();
      const operator = this.input[this.index];
      if (operator !== "*" && operator !== "/") return value;
      this.index += 1;
      const right = this.factor();
      value = operator === "*" ? value * right : value / right;
    }
  }

  private factor(): number {
    this.skipSpaces();
    const character = this.input[this.index];
    if (character === "+" || character === "-") {
      this.index += 1;
      const value = this.factor();
      return character === "-" ? -value : value;
    }
    if (character === "(") {
      this.index += 1;
      const value = this.expression();
      this.skipSpaces();
      if (this.input[this.index] !== ")") throw new Error("Missing parenthesis");
      this.index += 1;
      return value;
    }

    const start = this.index;
    while (/[0-9.]/.test(this.input[this.index] ?? "")) this.index += 1;
    const token = this.input.slice(start, this.index);
    if (!token || (token.match(/\./g)?.length ?? 0) > 1) throw new Error("Invalid number");
    const value = Number(token);
    if (!Number.isFinite(value)) throw new Error("Invalid number");
    return value;
  }

  private skipSpaces(): void {
    while (this.input[this.index] === " ") this.index += 1;
  }
}

function arithmeticAnswer(query: string): InstantAnswer | null {
  const expression = query
    .toLocaleLowerCase()
    .replace(/,/g, "")
    .replace(/=/g, "")
    .replace(/÷/g, "/")
    .replace(/×/g, "*")
    .replace(/(?<=[\d)])\s*x\s*(?=[\d(])/g, "*")
    .trim();

  if (
    !expression ||
    !/[+\-*/]/.test(expression) ||
    !/\d/.test(expression) ||
    !/^[\d.+\-*/()\s]+$/.test(expression)
  ) {
    return null;
  }

  const value = new ArithmeticParser(expression).parse();
  if (value === null) return null;
  return { title: `= ${format(value)}`, subtitle: "Instant calculation" };
}

function conversionAnswer(query: string): InstantAnswer | null {
  const match = query
    .trim()
    .match(/^([\d.,]+)\s*°?\s*([a-z]+)\s+(?:to|in|as)\s+°?\s*([a-z]+)$/i);
  if (!match) return null;

  const value = Number(match[1].replace(/,/g, ""));
  const fromName = match[2].toLocaleLowerCase();
  const toName = match[3].toLocaleLowerCase();
  if (!Number.isFinite(value)) return null;

  const temperatures: Record<string, "c" | "f"> = {
    c: "c",
    celsius: "c",
    f: "f",
    fahrenheit: "f",
  };
  const fromTemperature = temperatures[fromName];
  const toTemperature = temperatures[toName];
  if (fromTemperature && toTemperature && fromTemperature !== toTemperature) {
    const result =
      fromTemperature === "c" ? value * (9 / 5) + 32 : (value - 32) * (5 / 9);
    return {
      title: `${format(value)}°${fromTemperature.toUpperCase()} = ${format(result)}°${toTemperature.toUpperCase()}`,
      subtitle: "Instant temperature conversion",
    };
  }

  const from = units.get(fromName);
  const to = units.get(toName);
  if (!from || !to || from.category !== to.category) return null;
  const result = (value * from.toBase) / to.toBase;
  return {
    title: `${format(value)} ${from.label} = ${format(result)} ${to.label}`,
    subtitle: "Instant unit conversion",
  };
}

export function getInstantAnswer(query: string): InstantAnswer | null {
  return conversionAnswer(query) ?? arithmeticAnswer(query);
}
