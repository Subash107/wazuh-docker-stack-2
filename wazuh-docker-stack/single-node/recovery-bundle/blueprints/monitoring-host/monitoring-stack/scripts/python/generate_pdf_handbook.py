#!/usr/bin/env python3
import os
import re
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import Paragraph, Preformatted, SimpleDocTemplate, Spacer


REPO_ROOT = Path(
    os.getenv("MONITORING_REPO_ROOT")
    or Path(__file__).resolve().parents[2]
)
DOCS_ROOT = REPO_ROOT / "docs" / "operator-handbook"
PDF_ROOT = REPO_ROOT / "docs" / "pdf-handbook"

DOC_MAP = [
    ("project-overview.md", "project-overview.pdf", "Project Overview"),
    ("installation-guide.md", "installation-guide.pdf", "Installation Guide"),
    ("troubleshooting.md", "troubleshooting-guide.pdf", "Troubleshooting Guide"),
    ("tools-user-guide.md", "tools-user-guide.pdf", "Tools User Guide"),
    ("access-and-credentials.md", "access-and-credentials.pdf", "Access And Credentials"),
    (
        "monitoring-and-threat-identification-guide.md",
        "monitoring-and-threat-identification-guide.pdf",
        "Monitoring And Threat Identification Guide",
    ),
]


def build_styles():
    styles = getSampleStyleSheet()
    styles.add(
        ParagraphStyle(
            name="BodyCompact",
            parent=styles["BodyText"],
            fontName="Helvetica",
            fontSize=10,
            leading=14,
            textColor=colors.HexColor("#1f2933"),
            alignment=TA_LEFT,
            spaceAfter=6,
        )
    )
    styles.add(
        ParagraphStyle(
            name="Heading1Compact",
            parent=styles["Heading1"],
            fontName="Helvetica-Bold",
            fontSize=20,
            leading=24,
            textColor=colors.HexColor("#14213d"),
            spaceAfter=12,
        )
    )
    styles.add(
        ParagraphStyle(
            name="Heading2Compact",
            parent=styles["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=15,
            leading=18,
            textColor=colors.HexColor("#264653"),
            spaceBefore=10,
            spaceAfter=8,
        )
    )
    styles.add(
        ParagraphStyle(
            name="Heading3Compact",
            parent=styles["Heading3"],
            fontName="Helvetica-Bold",
            fontSize=12,
            leading=15,
            textColor=colors.HexColor("#3d405b"),
            spaceBefore=8,
            spaceAfter=6,
        )
    )
    styles.add(
        ParagraphStyle(
            name="MetaCompact",
            parent=styles["BodyText"],
            fontName="Helvetica-Oblique",
            fontSize=9,
            leading=12,
            textColor=colors.HexColor("#6b7280"),
            spaceAfter=10,
        )
    )
    return styles


def inline_markdown_to_html(text):
    text = escape(text)
    text = re.sub(r"`([^`]+)`", r"<font name='Courier'>\1</font>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", text)
    return text


def markdown_to_story(markdown_text, title, styles):
    story = [
        Paragraph(escape(title), styles["Heading1Compact"]),
        Paragraph("Generated from the operator handbook.", styles["MetaCompact"]),
    ]
    lines = markdown_text.splitlines()
    paragraph_buffer = []
    in_code_block = False
    code_buffer = []

    def flush_paragraph():
        if paragraph_buffer:
            text = " ".join(part.strip() for part in paragraph_buffer if part.strip())
            if text:
                story.append(Paragraph(inline_markdown_to_html(text), styles["BodyCompact"]))
            paragraph_buffer.clear()

    def flush_code():
        if code_buffer:
            story.append(
                Preformatted(
                    "\n".join(code_buffer),
                    ParagraphStyle(
                        "CodeCompact",
                        fontName="Courier",
                        fontSize=8.5,
                        leading=11,
                        textColor=colors.HexColor("#111827"),
                        backColor=colors.HexColor("#f3f4f6"),
                        leftIndent=8,
                        rightIndent=8,
                        borderPadding=8,
                        spaceAfter=8,
                    ),
                )
            )
            code_buffer.clear()

    for raw_line in lines:
        line = raw_line.rstrip()

        if line.startswith("```"):
            flush_paragraph()
            if in_code_block:
                flush_code()
                in_code_block = False
            else:
                in_code_block = True
            continue

        if in_code_block:
            code_buffer.append(line)
            continue

        if not line.strip():
            flush_paragraph()
            story.append(Spacer(1, 0.06 * inch))
            continue

        if line.startswith("# "):
            flush_paragraph()
            story.append(Paragraph(inline_markdown_to_html(line[2:].strip()), styles["Heading1Compact"]))
            continue
        if line.startswith("## "):
            flush_paragraph()
            story.append(Paragraph(inline_markdown_to_html(line[3:].strip()), styles["Heading2Compact"]))
            continue
        if line.startswith("### "):
            flush_paragraph()
            story.append(Paragraph(inline_markdown_to_html(line[4:].strip()), styles["Heading3Compact"]))
            continue

        if line.startswith("- ") or re.match(r"^\d+\.\s", line):
            flush_paragraph()
            bullet_text = line
            story.append(Paragraph(inline_markdown_to_html(bullet_text), styles["BodyCompact"]))
            continue

        if line.startswith("|"):
            flush_paragraph()
            story.append(
                Preformatted(
                    line,
                    ParagraphStyle(
                        "TableCompact",
                        fontName="Courier",
                        fontSize=8,
                        leading=10,
                        backColor=colors.HexColor("#faf7f0"),
                        borderPadding=5,
                        spaceAfter=4,
                    ),
                )
            )
            continue

        paragraph_buffer.append(line)

    flush_paragraph()
    flush_code()
    return story


def build_pdf(source_name, output_name, title, styles):
    source_path = DOCS_ROOT / source_name
    output_path = PDF_ROOT / output_name
    markdown_text = source_path.read_text(encoding="utf-8")
    story = markdown_to_story(markdown_text, title, styles)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    document = SimpleDocTemplate(
        str(output_path),
        pagesize=A4,
        leftMargin=0.65 * inch,
        rightMargin=0.65 * inch,
        topMargin=0.7 * inch,
        bottomMargin=0.7 * inch,
        title=title,
    )
    document.build(story)
    print(f"Generated {output_path}")


def main():
    styles = build_styles()
    for source_name, output_name, title in DOC_MAP:
        build_pdf(source_name, output_name, title, styles)


if __name__ == "__main__":
    main()
