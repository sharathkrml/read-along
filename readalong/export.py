"""Read Along — page export.

Renders a page JPEG with the current/next phrase boxes (amber/blue) or, in
proof mode, every word box, for the Edit-text workflow.
"""

from __future__ import annotations

from PIL import Image, ImageDraw


def export_image(app, mode: str, page: int = -1) -> bytes:
    st = app.state()
    model = app.model
    if not model or not model.get("pages"):
        raise ValueError("no page loaded")
    if page < 0 or page >= len(model["pages"]):
        page = st.get("page", 0)
    src = Image.open(app.workspace / "pages" / model["pages"][page]["image"]).convert("RGBA")
    W, H = src.size
    layer = Image.new("RGBA", src.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    amber = (245, 185, 66, 255)
    blue = (90, 169, 255, 255)
    lw = max(3, int(W * 0.0035))

    def draw_box(b, color, fill, width):
        x, y, w, h = b
        pad = W * 0.006
        d.rounded_rectangle(
            [x * W - pad, y * H - pad, (x + w) * W + pad, (y + h) * H + pad],
            radius=int(W * 0.012), outline=color, width=width, fill=fill,
        )

    if mode == "proof" or page != st.get("page", 0):
        for word in model["words"]:
            if word.get("page") == page and word.get("box"):
                draw_box(word["box"], (245, 185, 66, 150), None, max(2, lw // 2))
    else:
        for b in st["current_boxes"]:
            draw_box(b, amber, (245, 185, 66, 40), lw)
        for b in st["next_boxes"]:
            draw_box(b, blue, (90, 169, 255, 30), lw)

    out = Image.alpha_composite(src, layer).convert("RGB")
    buf = io.BytesIO()
    out.save(buf, "JPEG", quality=92)
    return buf.getvalue()
