// SF Symbols named by the Mac (workspace icons, task states, artifact types), drawn with Lucide outlines or
// small filled glyphs like the Mac's ".fill" symbols. Local to Home's Tasks and Artifacts.
import type { JSX } from "preact";
import {
  Archive, Award, Backpack, BadgeCheck, Banknote, Bed, Bell, Bike, Bird, BookOpen, Box, Brain, Briefcase, Building2, Bus,
  Calculator, Calendar, CalendarDays, Camera, Car, Cat, ChartColumn, ChartLine, ChartPie, CircleHelp, ClipboardList,
  Clapperboard, Clock, Cloud, Code, Coffee, Contact, CreditCard, Crown, Database, DollarSign, Dog, Droplet, Dumbbell, File as FileIcon,
  FileSignature, FileText, Film, Fish, Flag, Flame, Flower, Folder, Fuel, Gamepad2, Gauge, Gift, Globe, GraduationCap,
  HardDrive, Headphones, Heart, HeartPulse, Hammer, Hotel, House, IdCard, Image as ImageIcon, Inbox, Key, Landmark, Laptop, Layers,
  Library, Lightbulb, Link, ListChecks, Lock, Luggage, Mail, Map as MapIcon, MapPin, Medal, Megaphone, MessageSquare, Mic, Moon,
  Mountain, Music, Newspaper, NotebookPen, Package, Palette, PawPrint, Pencil, Phone, Pill, Plane, Printer, Puzzle, Receipt,
  Repeat, Scissors, Send, Search, Server, Shield, Shirt, Ship, ShoppingBag, ShoppingCart, Smartphone, Snowflake, Sparkles,
  SquarePlay, Star, Stethoscope, StickyNote, Sun, Tag, Target, Tent, Terminal, Thermometer, Ticket, Train, Trees, Trophy,
  Truck, Tv, Umbrella, User, Users, Utensils, Video, Wallet, Watch, Wrench, Zap, AudioWaveform,
} from "lucide";
import type { IconNode } from "lucide";

const SYMBOLS: Record<string, IconNode> = {
  briefcase: Briefcase, "case": Briefcase, envelope: Mail, "envelope.open": Mail, mail: Mail, "mail.stack": Mail,
  creditcard: CreditCard, airplane: Plane, "airplane.departure": Plane, "airplane.arrival": Plane, cart: ShoppingCart,
  bag: ShoppingBag, heart: Heart, car: Car, "car.side": Car, graduationcap: GraduationCap, book: BookOpen,
  "book.closed": BookOpen, "books.vertical": Library, gift: Gift, tag: Tag, "chart.line.uptrend.xyaxis": ChartLine,
  "chart.xyaxis.line": ChartLine, "chart.bar": ChartColumn, "chart.bar.xaxis": ChartColumn, "chart.pie": ChartPie,
  person: User, "person.crop": User, "person.2": Users, "person.3": Users, "person.crop.rectangle": IdCard,
  "person.text.rectangle": Contact, "person.crop.square": Contact, mappin: MapPin, "mappin.and.ellipse": MapPin,
  location: MapPin, shippingbox: Package, "box.truck": Truck, truck: Truck, newspaper: Newspaper, doc: FileIcon,
  "doc.text": FileText, "doc.plaintext": FileText, "doc.richtext": FileText, "text.document": FileText,
  "doc.on.doc": FileText, receipt: Receipt, banknote: Banknote, dollarsign: DollarSign, "building.2": Building2,
  building: Building2, "building.columns": Landmark, phone: Phone, "music.note": Music, "music.note.list": Music,
  dumbbell: Dumbbell, "figure.run": Dumbbell, "fork.knife": Utensils, stethoscope: Stethoscope, "cross.case": Stethoscope,
  pills: Pill, pill: Pill, globe: Globe, "chevron.left.forwardslash.chevron.right": Code, ladybug: Code, trophy: Trophy,
  target: Target, scope: Target, flag: Flag, bookmark: BadgeCheck, tray: Inbox, "tray.full": Inbox, "tray.2": Inbox,
  "bubble.left": MessageSquare, message: MessageSquare, "bubble.left.and.bubble.right": MessageSquare,
  "text.bubble": MessageSquare, lightbulb: Lightbulb, leaf: Trees, pawprint: PawPrint, ticket: Ticket,
  calendar: Calendar, "calendar.badge.clock": CalendarDays, "calendar.badge.plus": CalendarDays, checklist: ListChecks,
  "list.bullet.clipboard": ClipboardList, "list.clipboard": ClipboardList, clipboard: ClipboardList,
  "rectangle.stack": Layers, "square.stack": Layers, house: House, "wallet.pass": Wallet, "wallet.bifold": Wallet,
  bell: Bell, "arrow.triangle.2.circlepath": Repeat, repeat: Repeat, film: Film, movieclapper: Clapperboard,
  camera: Camera, tv: Tv, gamecontroller: Gamepad2, star: Star, folder: Folder, link: Link, megaphone: Megaphone,
  sparkles: Sparkles, bolt: Zap, brain: Brain, "brain.head.profile": Brain, "server.rack": Server, server: Server,
  terminal: Terminal, archivebox: Archive, "cup.and.saucer": Coffee, mug: Coffee, mic: Mic, video: Video,
  laptopcomputer: Laptop, iphone: Smartphone, applewatch: Watch, headphones: Headphones, bicycle: Bike, bus: Bus,
  tram: Train, ferry: Ship, map: MapIcon, "bed.double": Bed, scissors: Scissors, tshirt: Shirt, paintpalette: Palette,
  pencil: Pencil, "square.and.pencil": NotebookPen, "note.text": StickyNote, note: StickyNote, function: Calculator,
  "waveform.path.ecg": HeartPulse, "heart.text.square": HeartPulse, clock: Clock, hammer: Hammer, wrench: Wrench,
  "wrench.and.screwdriver": Wrench, lock: Lock, key: Key, cloud: Cloud, "sun.max": Sun, moon: Moon,
  magnifyingglass: Search, signature: FileSignature, "checkmark.seal": BadgeCheck, "house.lodge": Hotel,
  suitcase: Luggage, "suitcase.rolling": Luggage, medal: Medal, rosette: Award, crown: Crown, puzzlepiece: Puzzle,
  dog: Dog, cat: Cat, fish: Fish, bird: Bird, tree: Trees, "camera.macro": Flower, printer: Printer,
  externaldrive: HardDrive, cylinder: Database, shield: Shield, flame: Flame, drop: Droplet, snowflake: Snowflake,
  fuelpump: Fuel, gauge: Gauge, thermometer: Thermometer, umbrella: Umbrella, "mountain.2": Mountain, tent: Tent,
  backpack: Backpack, photo: ImageIcon, waveform: AudioWaveform, "play.rectangle": SquarePlay, questionmark: CircleHelp,
  cube: Box, "cube.box": Box, paperplane: Send,
};

/** "briefcase.fill" → Briefcase; drops ".fill", ".circle", ".square" variants; unknown names get the stack. */
export function symbolNode(name: string | undefined): IconNode {
  let key = (name ?? "").trim();
  for (;;) {
    const node = SYMBOLS[key];
    if (node) return node;
    const trimmed = key.replace(/\.(fill|circle|square|rectangle|badge\.[a-z]+|slash)$/, "");
    if (trimmed === key) return Layers;
    key = trimmed;
  }
}

export function SymbolIcon(props: { name: string | undefined; size?: number; class?: string; label?: string }): JSX.Element {
  const size = props.size ?? 16;
  return (
    <svg class={`icon${props.class ? ` ${props.class}` : ""}`} viewBox="0 0 24 24" width={size} height={size}
      style={{ width: `${size}px`, height: `${size}px` }} aria-hidden={props.label ? undefined : "true"}
      role={props.label ? "img" : undefined} aria-label={props.label} focusable="false">
      {symbolNode(props.name).map(([tag, attrs], index) => {
        const Tag = tag as "path";
        return <Tag key={index} {...(attrs as Record<string, string>)} />;
      })}
    </svg>
  );
}

function Glyph(props: { size: number; label?: string; children: JSX.Element | JSX.Element[] }): JSX.Element {
  return (
    <svg width={props.size} height={props.size} viewBox="0 0 24 24" class="hm-glyph" focusable="false"
      role={props.label ? "img" : undefined} aria-label={props.label} aria-hidden={props.label ? undefined : "true"}>
      {props.children}
    </svg>
  );
}

/** exclamationmark.triangle.fill */
export function WarningGlyph(props: { size?: number; color?: string; label?: string }): JSX.Element {
  return (
    <Glyph size={props.size ?? 16} label={props.label}>
      <path d="M10.3 3.4a2 2 0 0 1 3.4 0l8.6 15a2 2 0 0 1-1.7 3H3.4a2 2 0 0 1-1.7-3z" fill={props.color ?? "var(--orange)"} />
      <path d="M12 9v5" stroke="#1c1c1e" stroke-width="2.2" stroke-linecap="round" />
      <circle cx="12" cy="17.6" r="1.25" fill="#1c1c1e" />
    </Glyph>
  );
}

/** pause.circle.fill in the secondary color. */
export function PausedGlyph(props: { size?: number; label?: string }): JSX.Element {
  return (
    <Glyph size={props.size ?? 16} label={props.label}>
      <circle cx="12" cy="12" r="11" fill="rgba(235,235,245,.6)" />
      <path d="M9.5 8v8M14.5 8v8" stroke="#232426" stroke-width="2.4" stroke-linecap="round" />
    </Glyph>
  );
}

/** clock.fill in blue: a scheduled task waiting for its next run. */
export function ScheduledGlyph(props: { size?: number; label?: string }): JSX.Element {
  return (
    <Glyph size={props.size ?? 16} label={props.label}>
      <circle cx="12" cy="12" r="11" fill="var(--accent)" />
      <path d="M12 6.5V12l3.6 2.2" stroke="#fff" stroke-width="2.2" fill="none" stroke-linecap="round" stroke-linejoin="round" />
    </Glyph>
  );
}

/** questionmark.bubble.fill in the active tint. */
export function NeedsInputGlyph(props: { size?: number; label?: string }): JSX.Element {
  return (
    <Glyph size={props.size ?? 16} label={props.label}>
      <path d="M5 2.5h14a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3h-6.2L7.5 21.6V17.5H5a3 3 0 0 1-3-3v-9a3 3 0 0 1 3-3z" fill="var(--active-tint)" />
      <path d="M9.6 7.9a2.5 2.5 0 1 1 3.4 2.3c-.7.3-1 .8-1 1.5v.4" stroke="#1c1200" stroke-width="2" fill="none" stroke-linecap="round" />
      <circle cx="12" cy="15" r="1.15" fill="#1c1200" />
    </Glyph>
  );
}

/** doc.text.fill / doc.richtext.fill, play.rectangle.fill: the Mac's filled artifact type glyphs. */
export function ArtifactTypeGlyph(props: { name: string; size?: number }): JSX.Element {
  const size = props.size ?? 34;
  if (props.name === "doc.text.fill" || props.name === "doc.richtext.fill") {
    return (
      <Glyph size={size}>
        <path d="M6.5 1.5h7.3L19.5 7.2V20a2.5 2.5 0 0 1-2.5 2.5H6.5A2.5 2.5 0 0 1 4 20V4a2.5 2.5 0 0 1 2.5-2.5z" fill="currentColor" />
        <path d="M13.5 1.6V6a1.5 1.5 0 0 0 1.5 1.5h4.4" fill="none" stroke="var(--hm-glyph-cut, #1f2a3a)" stroke-width="1.2" />
        {props.name === "doc.text.fill"
          ? <path d="M8 12h7.5M8 15h7.5M8 18h5" stroke="var(--hm-glyph-cut, #1f2a3a)" stroke-width="1.5" stroke-linecap="round" />
          : <>
            <circle cx="9.3" cy="12" r="1.3" fill="var(--hm-glyph-cut, #1f2a3a)" />
            <path d="M7.5 18.5l3-3.2 2 2 1.6-1.6 2.4 2.8z" fill="var(--hm-glyph-cut, #1f2a3a)" />
          </>}
      </Glyph>
    );
  }
  if (props.name === "play.rectangle.fill") {
    return (
      <Glyph size={size}>
        <rect x="1.5" y="4" width="21" height="16" rx="3.5" fill="currentColor" />
        <path d="M10 8.6v6.8l5.6-3.4z" fill="var(--hm-glyph-cut, #1f2a3a)" />
      </Glyph>
    );
  }
  return <SymbolIcon name={props.name} size={size} />;
}
