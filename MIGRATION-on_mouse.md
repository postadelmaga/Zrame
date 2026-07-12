# Migrazione: `on_mouse` ora consegna coordinate in spazio app (non canvas)

**Data:** 2026-07-11 · **Impatto:** ogni app zrame che usa `on_mouse` · **Costo tipico:** 3 righe

## Cosa è cambiato

Prima, `on_mouse` consegnava il mouse in **coordinate canvas**: origine sull'angolo del
buffer finestra, gutter dell'ombra e titlebar inclusi. Ogni app doveva ricordarsi di
sottrarre l'offset del chrome prima di fare hit-test — e nessuna lo faceva davvero:
in zuer la scrollbar si attivava ~10 px fuori dal punto disegnato (il margine del
frame di vetro), e lo stesso sfasamento silenzioso colpiva selezione testo, controlli
video e zoom-verso-cursore.

Adesso la traduzione la fa **zrame, una volta sola**, come nei toolkit consolidati
(client area di Win32, view coords di Cocoa, logical presentation di SDL: le
coordinate le normalizza chi disegna la decorazione, mai l'app). Il contratto nuovo,
documentato su `zrame.MouseEvent` (`src/window.zig`):

> Le coordinate di `.motion` sono nello **spazio di presentazione dell'app**:
> - se l'app stagia frame con `presentRgba` → origine sull'angolo del frame staged
>   (zrame lo centra nel vetro; la stessa matematica del blit, `chrome.frameOrigin`);
> - altrimenti (app solo `on_draw`) → origine sull'angolo del **content rect**.
>
> L'app fa hit-test con le stesse coordinate con cui ha disegnato. Gutter, titlebar
> e centratura non esistono più fuori da zrame. Pannelli e resize band restano in
> coordinate canvas *dentro* zrame (spazio "non-client").

`.button` non porta coordinate (usate l'ultima `.motion`: eredita la correzione),
`.leave` è invariato. Anche il percorso touch è già tradotto.

## Chi deve fare cosa

**App `presentRgba` (stile zuer):** niente. È il caso per cui il contratto è nato —
se compensavate a mano l'offset (margine o centratura del fit-rect), *togliete* la
compensazione, ora arriva già giusto.

**App `on_draw` (stile ZenFlow2, esempio `widgets`):** disegnate sul canvas grezzo
posizionandovi a `content.x/y`, quindi il mouse — che ora arriva content-local — va
riportato in spazio canvas aggiungendo l'origine del content rect:

```zig
fn onMouse(win: *zrame.Window, event: zrame.MouseEvent, user: ?*anyopaque) bool {
    ...
    // on_mouse arriva in coordinate contenuto (questa app non stagia frame), ma la
    // UI disegna sul canvas grezzo con origine a content.x/y: riporta il mouse in canvas.
    const c = win.host().info().content;
    switch (event) {
        .motion => |m| {
            const mx = m.x + @as(f32, @floatFromInt(c.x));
            const my = m.y + @as(f32, @floatFromInt(c.y));
            ...
        },
        ...
    }
}
```

Il riferimento completo è `examples/widgets.zig` (già migrato). I *delta* (pan,
orbita, drag relativi) non cambiano: l'offset è costante e si elide nella
differenza. Cambiano solo gli hit-test **assoluti** contro geometrie basate su
`content.x/y` (bordi colonna, header, palchi): senza la rimappa risultano sfasati
di `margin` (e di `titlebar_height` se attiva).

## Come verificare

1. Ricompilate contro lo zrame aggiornato (dipendenza path: basta `zig build`).
2. Portate il mouse su un bersaglio *sottile* vicino a un bordo (maniglia di resize
   colonna, scrollbar, tab): deve attivarsi esattamente dove è disegnato, non
   ~10 px più in là verso l'interno.
3. Se avete una titlebar zrame attiva, ripetete il test su un bersaglio in alto.

## Perché non in zicro

zicro è il layer di pittura: `Canvas` è pixel nudi, `scroll.Scroll` hit-testa
correttamente nel viewport che le date. L'offset nasce dal chrome di zrame
(margine, titlebar, centratura del frame staged), e chi crea l'offset lo nasconde —
zrame dipende da zicro, non viceversa; insegnargli il frame di vetro invertirebbe
il layering.
