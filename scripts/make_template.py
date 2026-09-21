#!/usr/bin/env python3
"""
Build the master-data entry workbook.

The column headers are a contract: they are the exact field names
public.import_masters expects. Change one here and the importer stops
recognising it, so keep the two in step.

    python3 scripts/make_template.py [output.xlsx]
"""

import sys
from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

FONT = "Arial"

REQUIRED_FILL = PatternFill("solid", fgColor="1F3864")   # dark blue
OPTIONAL_FILL = PatternFill("solid", fgColor="8497B0")   # muted blue
EXAMPLE_FILL  = PatternFill("solid", fgColor="FFF2CC")   # pale yellow
TITLE_FILL    = PatternFill("solid", fgColor="F2F2F2")

THIN = Side(style="thin", color="BFBFBF")
BORDER = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)

# (field, required, width, help text, example value)
SHEETS = [
    ("1. Routes", "route", [
        ("code", True,  14, "Short code you will type elsewhere, e.g. R1. Must be unique.", "EXAMPLE-R"),
        ("name", True,  32, "Full route name, e.g. Biratnagar Town.", "Example Route"),
    ]),

    ("2. Product Groups", "product_group", [
        ("code", True,  14, "Short code, e.g. G1. Must be unique.", "EXAMPLE-G"),
        ("name", True,  32, "Group name, e.g. Biscuits.", "Example Group"),
    ]),

    ("3. Suppliers", "supplier", [
        ("code",           True,  14, "Short code, e.g. S1. Must be unique.", "EXAMPLE-S"),
        ("name",           True,  32, "Supplier's full name.", "Example Supplier Pvt Ltd"),
        ("contact_person", False, 22, "Who you deal with there. Optional.", "Ramesh"),
        ("phone",          False, 16, "Optional.", "9800000000"),
        ("address",        False, 30, "Optional.", "Industrial Area"),
        ("city",           False, 16, "Optional.", "Biratnagar"),
    ]),

    ("4. Parties", "party", [
        ("code",                 True,  14, "Short code for the customer, e.g. C1. Must be unique.", "EXAMPLE-C"),
        ("name",                 True,  32, "Customer's full name as it should print on the invoice.", "Example Store"),
        ("route_code",           True,  14, "Must match a code from the Routes sheet exactly.", "EXAMPLE-R"),
        ("contact_person",       False, 22, "Optional.", "Sita"),
        ("phone",                False, 16, "Optional.", "9800000001"),
        ("whatsapp_phone",       False, 16, "Only if different from phone. Left blank, phone is used.", ""),
        ("address",              False, 30, "Prints on the invoice. Optional.", "Main Road"),
        ("city",                 False, 16, "Optional.", "Biratnagar"),
        ("credit_limit",         False, 14, "Leave blank or 0 for no limit.", 50000),
        ("credit_days",          False, 12, "Payment terms in days. Whole number.", 30),
        ("opening_balance",      False, 16, "What they owed you on the go-live date. Blank or 0 if nothing.", 12500),
        ("opening_balance_date", False, 20, "Required if opening_balance is not zero. Type as YYYY-MM-DD.", "2026-04-01"),
    ]),

    ("5. Products", "product", [
        ("code",          True,  14, "Short code, e.g. P1. Must be unique.", "EXAMPLE-P"),
        ("name",          True,  32, "Product name as it should print on the invoice.", "Example Biscuit 100g"),
        ("group_code",    True,  14, "Must match a code from the Product Groups sheet exactly.", "EXAMPLE-G"),
        ("base_uom",      True,  12, "The unit you SELL in and count stock in, e.g. PCS, KG, LTR.", "PCS"),
        ("pack_uom",      False, 12, "Only if you also buy or sell by the pack, e.g. BOX. Otherwise blank.", "BOX"),
        ("pack_size",     False, 12, "How many base units in one pack. 1 BOX = 24 PCS means 24.", 24),
        ("sale_price",    False, 12, "Selling price of ONE PACK (one BOX) if you filled pack_uom; otherwise per base unit. The app works out the per-piece rate. Editable on each bill.", 600),
        ("purchase_price", False, 14, "Your cost of ONE PACK if you filled pack_uom; otherwise per base unit. Used for margin reports.", 480),
        ("opening_qty",   False, 14, "Stock on hand at go-live, in BASE units (pieces). 10 boxes of 24 = 240, or type =10*24.", 480),
        ("opening_price", False, 14, "Cost of that opening stock, per PACK if you filled pack_uom, otherwise per base unit. Usually the same as purchase_price.", 480),
        ("opening_date",  False, 14, "Required if opening_qty is above zero. Type as YYYY-MM-DD.", "2026-04-01"),
    ]),
]

TEXT_COLUMNS = {"opening_balance_date", "opening_date"}


def add_instructions(wb):
    ws = wb.create_sheet("Read me first", 0)
    ws.sheet_view.showGridLines = False

    lines = [
        ("Sales App — master data", "title"),
        ("", None),
        ("Fill in the five sheets in the order they are numbered. Parties point at "
         "Routes, and Products point at Product Groups, so those must exist first.", "body"),
        ("", None),
        ("Before you import", "head"),
        ("Row 2 of every sheet is an EXAMPLE, shaded yellow. Delete that row before "
         "importing. If you forget, the import will refuse and tell you which row — "
         "it will not create a customer called Example Store.", "body"),
        ("", None),
        ("Column headers", "head"),
        ("Do not rename, reorder or delete the header row. Those names are how the "
         "app recognises each column. Hover any header for a note on what it means.", "body"),
        ("Dark blue headers are required. Lighter blue are optional — leave them blank "
         "if you do not have the information.", "body"),
        ("", None),
        ("Codes", "head"),
        ("A code is a short unique label you will type instead of the full name — R1 "
         "for a route, C1 for a customer. Keep them short and consistent. They cannot "
         "be changed later without effort, so decide the pattern now.", "body"),
        ("Codes must be unique within each sheet. The import checks this and names any "
         "duplicate row.", "body"),
        ("", None),
        ("Dates", "head"),
        ("Type dates as YYYY-MM-DD, for example 2026-04-01. Those columns are already "
         "formatted as text so Excel will not reformat what you type.", "body"),
        ("", None),
        ("Numbers", "head"),
        ("Type plain numbers with no commas and no currency symbol. 12500, not 12,500 "
         "and not Rs 12,500. The import will reject anything it cannot read as a "
         "number, naming the row and column.", "body"),
        ("", None),
        ("Units and packs", "head"),
        ("base_uom is the unit you sell in and count stock in. If you also deal in "
         "packs, set pack_uom and pack_size — one BOX of 24 PCS means base_uom PCS, "
         "pack_uom BOX, pack_size 24. Stock is always held in base units; the app "
         "converts when someone orders by the box.", "body"),
        ("Leave pack_uom and pack_size blank for anything sold loose.", "body"),
        ("Prices follow the pack. If a product has a pack_uom, type sale_price, "
         "purchase_price and opening_price for ONE PACK — a box of 24 at 500 means "
         "sale_price 500. The app keeps 500 exactly for billing by the box and works "
         "out the per-piece rate (20.8333) for loose sales. Without a pack, the price "
         "is per base unit.", "body"),
        ("Quantities do not follow the pack: opening_qty is always in base units, "
         "because loose stock rarely fills whole boxes.", "body"),
        ("", None),
        ("Opening balances", "head"),
        ("opening_balance is what a customer owed you on the day you start using the "
         "app, and it needs a date so the ageing report can work. opening_qty is the "
         "stock on your shelf that day. Both can be left blank if they are zero.", "body"),
        ("", None),
        ("Nothing is imported unless everything is correct", "head"),
        ("The import checks the whole sheet first. If any row has a problem, nothing "
         "at all is written and you get a list of what to fix, by row and column. A "
         "half-imported customer list is worse than none, because you cannot tell "
         "which half is missing.", "body"),
    ]

    styles = {
        "title": (Font(name=FONT, size=16, bold=True, color="1F3864"), None),
        "head":  (Font(name=FONT, size=11, bold=True, color="1F3864"), TITLE_FILL),
        "body":  (Font(name=FONT, size=10), None),
    }

    r = 1
    for text, kind in lines:
        if kind:
            c = ws.cell(row=r, column=1, value=text)
            font, fill = styles[kind]
            c.font = font
            if fill:
                c.fill = fill
            c.alignment = Alignment(wrap_text=True, vertical="top")
            if kind == "body":
                ws.row_dimensions[r].height = 15 * (1 + len(text) // 95)
        r += 1

    ws.column_dimensions["A"].width = 100
    return ws


def add_sheet(wb, title, entity, columns):
    ws = wb.create_sheet(title)
    ws.sheet_view.showGridLines = False

    for i, (field, required, width, help_text, example) in enumerate(columns, start=1):
        letter = get_column_letter(i)
        ws.column_dimensions[letter].width = width

        h = ws.cell(row=1, column=i, value=field)
        h.font = Font(name=FONT, size=10, bold=True, color="FFFFFF")
        h.fill = REQUIRED_FILL if required else OPTIONAL_FILL
        h.alignment = Alignment(horizontal="left", vertical="center", wrap_text=True)
        h.border = BORDER
        h.comment = Comment(
            f"{'REQUIRED' if required else 'Optional'}\n\n{help_text}", "Sales App", height=120, width=260
        )

        e = ws.cell(row=2, column=i, value=example if example != "" else None)
        e.font = Font(name=FONT, size=10, italic=True, color="7F6000")
        e.fill = EXAMPLE_FILL
        e.border = BORDER

        if field in TEXT_COLUMNS:
            for row in range(2, 400):
                ws.cell(row=row, column=i).number_format = "@"

    ws.row_dimensions[1].height = 30
    ws.freeze_panes = "A3"

    # Plain-language note under the example, out of the way of the data.
    note = ws.cell(row=2, column=len(columns) + 2,
                   value="^ Example row — delete before importing")
    note.font = Font(name=FONT, size=9, italic=True, color="7F6000")

    ws.cell(row=1, column=len(columns) + 2, value=f"(imports as: {entity})") \
      .font = Font(name=FONT, size=9, color="808080")

    return ws


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "sales-app-master-data.xlsx"

    wb = Workbook()
    wb.remove(wb.active)

    add_instructions(wb)
    for title, entity, columns in SHEETS:
        add_sheet(wb, title, entity, columns)

    wb.active = 0
    wb.save(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
