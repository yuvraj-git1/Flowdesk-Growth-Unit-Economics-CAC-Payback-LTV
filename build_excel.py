"""Build excel/flowdesk_budget_model.xlsx from outputs/ (stage 2-4 CSVs). All model cells are live formulas;
Channel_Data holds the SQL results as values (the evidence), Assumptions holds the levers + scenario toggle."""
import pandas as pd
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.workbook.defined_name import DefinedName
from openpyxl.formatting.rule import CellIsRule, FormulaRule
from openpyxl.utils import get_column_letter as L

PAID = ["paid_search", "paid_social", "affiliate", "review_site"]
ue = pd.read_csv("outputs/s2_05_channel_unit_economics.csv").set_index("channel")
yr = pd.read_csv("outputs/s2_10_marginal_cac_by_year.csv"); y25 = yr[yr.y == 2025].set_index("channel")
sp = pd.read_csv("outputs/tb02_spend_monthly.csv"); sp["y"] = sp.ym.str[:4]; sp25 = sp[sp.y == "2025"].groupby("channel").spend_usd.sum()
cu = pd.read_csv("outputs/tb01_customer_level.csv"); cu = cu[cu.cohort_ok == 1]
sa = cu.groupby("channel").motion.apply(lambda s: (s == "sales_assisted").mean())
ci = pd.read_csv("outputs/st01_ci_channel.csv").set_index("segment")
att = pd.read_csv("outputs/s3_01_channel_totals.csv").set_index("channel")
cp = pd.read_csv("outputs/st03_coupon_sensitivity.csv").set_index("segment")
sc = pd.read_csv("outputs/s4_03_sales_cac.csv").iloc[0]

wb = Workbook(); H = Font(bold=True, color="FFFFFF"); HF = PatternFill("solid", fgColor="1F3A5F")
INP = PatternFill("solid", fgColor="FFF2CC"); INF = Font(color="0000FF"); B = Font(bold=True)
thin = Side(style="thin", color="BBBBBB"); BOX = Border(top=thin, bottom=thin, left=thin, right=thin)
def hdr(ws, r, vals, c0=1):
    for j, v in enumerate(vals):
        x = ws.cell(r, c0 + j, v); x.font = H; x.fill = HF; x.alignment = Alignment(wrap_text=True, vertical="center")
def name(n, ref): wb.defined_names[n] = DefinedName(n, attr_text=ref)

# ---------------- README ----------------
ws = wb.active; ws.title = "README"
for i, t in enumerate([
    "Flowdesk: next $50K paid-acquisition budget model", "",
    "1. Assumptions!B3 picks the scenario (Base / Conservative / Optimistic). Assumptions!B4 picks the allocation plan.",
    "2. Yellow cells with blue text are inputs. Everything on Model and Plan_Compare is a live formula.",
    "3. Channel_Data = SQL results (p3/sql/02-04, matured cohorts signed up 2023-01 to 2025-09). Do not edit; re-export to refresh.",
    "4. Marginal CAC = 2025 cohort CAC x scenario multiplier x (1 + elasticity x extra spend / 2025 spend): diminishing returns.",
    "5. Fully loaded CAC adds sales cost for the share of each channel's customers that are sales-assisted.",
    "6. LTV = ARPA x GM x (1-(1-churn)^H)/churn (H = horizon cap). Payback = fully loaded CAC / (ARPA x GM).",
    "7. Call: Scale if LTV:CAC >= Scale threshold AND payback <= max months; Hold if LTV:CAC >= Hold threshold; else Cut.",
    "8. Custom plan allows negatives (take budget out of a channel). Plan_Compare!B? check must show 0 (allocations sum to budget).",
    "", "Caveats: gross margin and sales cost are NOT in the data (assumptions). Review-site sample is small (50 customers): see CI columns.",
    "P3 extract shows 100% discount on every coupon invoice; Optimistic scenario re-prices them with P1 discounts (+10-25% revenue)."]):
    ws.cell(i + 1, 1, t).font = Font(bold=(i == 0), size=14 if i == 0 else 11)
ws.column_dimensions["A"].width = 130

# ---------------- Assumptions ----------------
A = wb.create_sheet("Assumptions"); A.column_dimensions["A"].width = 46; A.column_dimensions["G"].width = 70
for c in "BCDEF": A.column_dimensions[c].width = 15
A["A1"] = "Assumptions and scenario toggle"; A["A1"].font = Font(bold=True, size=14)
A["A3"] = "Scenario"; A["B3"] = "Base"; A["A4"] = "Allocation plan"; A["B4"] = "Recommended"
for c in ("B3", "B4"): A[c].fill = INP; A[c].font = Font(color="0000FF", bold=True); A[c].border = BOX
dv = DataValidation(type="list", formula1='"Base,Conservative,Optimistic"', allow_blank=False); A.add_data_validation(dv); dv.add("B3")
dv2 = DataValidation(type="list", formula1='"Current mix,Recommended,Custom"', allow_blank=False); A.add_data_validation(dv2); dv2.add("B4")
A["C3"] = "=MATCH(B3,C6:E6,0)"; A["C4"] = '=MATCH(B4,{"Current mix","Recommended","Custom"},0)'
A["D3"] = "<- scenario index"; A["D4"] = "<- plan index"
name("ScenIdx", "Assumptions!$C$3"); name("PlanIdx", "Assumptions!$C$4")
hdr(A, 6, ["Parameter", "Active", "Base", "Conservative", "Optimistic", "Unit", "Why / source"])
params = [
 ("GM", "Gross margin", 0.80, 0.75, 0.85, "%", "Not in data. Typical PLG SaaS 75-85%."),
 ("CAC_MULT", "CAC multiplier vs 2025 cohort CAC", 1.00, 1.15, 0.90, "x", "2025 conversion fell ~40% in every channel incl. organic (s2_10, P1 finding); Conservative assumes it worsens."),
 ("ELAST", "Diminishing-returns elasticity", 0.50, 1.00, 0.25, "x", "CAC rises ELAST% per +1% of spend vs 2025 run-rate. Not estimable from data (spend never varied much): assumption."),
 ("CHURN_BASIS", "Churn basis (1 = ex dunning outage, 2 = observed)", 1, 2, 1, "flag", "P1: Feb-Jul 2025 dunning outage drove one-off involuntary churn; fixed going forward."),
 ("CHURN_MULT", "Churn multiplier", 1.00, 1.10, 0.90, "x", "Stress on monthly logo churn."),
 ("HORIZON", "LTV horizon cap (months)", 60, 36, 60, "months", "Caps LTV so low-churn channels are not credited forever."),
 ("SALES_COST", "Sales cost per sales-assisted customer", round(float(sc.sales_cac_touch_hour_75)), round(float(sc.sales_cac_loaded_8reps_90k)), 1000, "$", "Base = logged touch hours x $75/h (s4_03); Conservative = 8 reps x $90K loaded x 3y / customers."),
 ("COUPON_FLAG", "Re-price 100%-coupon invoices with P1 discounts (0/1)", 0, 0, 1, "flag", "P3 extract: every coupon invoice is 100% off; P1 extract of same invoices: median 20%. Uplift per channel on Channel_Data."),
 ("BUDGET", "Incremental budget to allocate", 50000, 50000, 50000, "$", "The question: where should the next $50K go?"),
 ("SCALE_LTV", "Scale threshold: LTV:CAC >=", 3.0, 3.0, 3.0, "x", "Common SaaS bar."),
 ("SCALE_PB", "Scale threshold: payback <= (months)", 12, 12, 12, "months", "Cash discipline while burn is rising."),
 ("HOLD_LTV", "Hold threshold: LTV:CAC >=", 1.5, 1.5, 1.5, "x", "Below this the channel destroys value on a fully loaded basis -> Cut."),
]
for i, (nm, lab, b, c, o, u, why) in enumerate(params):
    r = 7 + i; A.cell(r, 1, lab); A.cell(r, 2, f"=INDEX(C{r}:E{r},ScenIdx)").font = B
    for j, v in enumerate((b, c, o)):
        x = A.cell(r, 3 + j, v); x.fill = INP; x.font = INF; x.border = BOX
    A.cell(r, 6, u); A.cell(r, 7, why).alignment = Alignment(wrap_text=True)
    fmt = "0%" if u == "%" else ("$#,##0" if u == "$" else "0.00" if u == "x" else "0")
    for j in range(2, 6): A.cell(r, j).number_format = fmt
    name(nm, f"Assumptions!$B${r}")

# ---------------- Channel_Data ----------------
D = wb.create_sheet("Channel_Data")
cols = ["Channel", "2025 spend (ref FX)", "2025 cohort CAC (Jan-Sep)", "All-period CAC", "Signups (matured)", "Customers", "Conv %",
        "ARPA net MRR (first invoice)", "Monthly churn observed", "Monthly churn ex-outage", "Sales-assisted share of customers",
        "P1-coupon revenue uplift", "LTV:CAC (GM80, all-period)", "LTV:CAC 95% CI low", "LTV:CAC 95% CI high",
        "Self-serve-only LTV:CAC", "Self-serve-only CI high", "Platform-claimed / DB paid conversions", "2025 conv %"]
hdr(D, 1, cols); D.row_dimensions[1].height = 60
for j in range(1, len(cols) + 1): D.column_dimensions[L(j)].width = 15
for i, ch in enumerate(PAID):
    r = 2 + i; s = f"{ch}|self_serve_only"
    vals = [ch, sp25[ch], y25.cac[ch], ue.cac[ch], ue.signups[ch], ue.customers[ch], ue.conv_pct[ch] / 100, ue.arpa_mrr[ch],
            ue.churn_pct_mo[ch] / 100, ue.churn_ex_outage_pct[ch] / 100, sa[ch], cp.uplift_pct[ch] / 100, ci.ltv_cac[ch],
            ci.ltv_cac_lo[ch], ci.ltv_cac_hi[ch], ci.ltv_cac[s], ci.ltv_cac_hi[s], att.paid_ratio[ch], y25.conv_pct[ch] / 100]
    for j, v in enumerate(vals):
        x = D.cell(r, 1 + j, float(v) if j else v)
        x.number_format = {1: "$#,##0", 2: "$#,##0", 3: "$#,##0", 6: "0.0%", 7: "$#,##0.0", 8: "0.00%", 9: "0.00%", 10: "0%", 11: "0.0%", 18: "0.0%"}.get(j, "#,##0.00")
D.cell(7, 1, "Source: outputs/s2_05, s2_10, tb02, tb01, st01 (bootstrap), s3_01, st03. Matured cohorts = signups 2023-01-01..2025-09-30.").font = Font(italic=True)
r0 = 9; D.cell(r0, 1, "Unpaid channels (no spend in data; reference only)").font = B
hdr(D, r0 + 1, ["Channel", "Signups", "Customers", "Conv %", "ARPA", "Churn obs", "LTV (GM80)"])
for i, ch in enumerate([c for c in ue.index if c not in PAID]):
    for j, v in enumerate([ch, ue.signups[ch], ue.customers[ch], ue.conv_pct[ch] / 100, ue.arpa_mrr[ch], ue.churn_pct_mo[ch] / 100, ue.ltv_gm80[ch]]):
        x = D.cell(r0 + 2 + i, 1 + j, float(v) if j else v); x.number_format = {3: "0.0%", 5: "0.00%"}.get(j, "#,##0")

# ---------------- Model ----------------
M = wb.create_sheet("Model"); M["A1"] = "Allocation model (selected scenario + plan)"; M["A1"].font = Font(bold=True, size=14)
M["A2"] = '="Scenario: "&Assumptions!B3&"   |   Plan: "&Assumptions!B4'
mc = ["Channel", "2025 spend", "Plan: Current mix", "Plan: Recommended", "Plan: Custom", "Selected allocation", "Marginal mkt CAC",
      "Fully loaded CAC", "New customers", "ARPA (adj)", "Monthly churn (adj)", "LTV per customer", "LTV:CAC", "Payback (months)",
      "12m GM cash / customer", "Total LTV", "Total cost (mkt + sales)", "Net value created", "Call", "Avg 2025 LTV:CAC (no extra spend)"]
hdr(M, 4, mc); M.row_dimensions[4].height = 45
for j in range(1, len(mc) + 1): M.column_dimensions[L(j)].width = 14
M.column_dimensions["A"].width = 16
rec = {"paid_search": 30000, "paid_social": 10000, "affiliate": 15000, "review_site": -5000}
for i, ch in enumerate(PAID):
    r = 5 + i; d = 2 + i  # Channel_Data row
    f = {
     "A": f"=Channel_Data!A{d}", "B": f"=Channel_Data!B{d}",
     "C": f"=BUDGET*B{r}/SUM($B$5:$B$8)", "D": rec[ch], "E": 0,
     "F": f"=CHOOSE(PlanIdx,C{r},D{r},E{r})",
     "G": f"=Channel_Data!C{d}*CAC_MULT*(1+ELAST*F{r}/B{r})",
     "H": f"=G{r}+Channel_Data!K{d}*SALES_COST",
     "I": f"=F{r}/G{r}",
     "J": f"=Channel_Data!H{d}*(1+COUPON_FLAG*Channel_Data!L{d})",
     "K": f"=IF(CHURN_BASIS=1,Channel_Data!J{d},Channel_Data!I{d})*CHURN_MULT",
     "L": f"=J{r}*GM*(1-(1-K{r})^HORIZON)/K{r}",
     "M": f"=L{r}/H{r}", "N": f"=H{r}/(J{r}*GM)",
     "O": f"=J{r}*GM*(1-(1-K{r})^12)/K{r}",
     "P": f"=I{r}*L{r}", "Q": f"=F{r}+I{r}*Channel_Data!K{d}*SALES_COST", "R": f"=P{r}-Q{r}",
     "S": f'=IF(AND(T{r}>=SCALE_LTV,N{r}<=SCALE_PB),"Scale",IF(T{r}>=HOLD_LTV,"Hold","Cut"))',
     "T": f"=L{r}/(Channel_Data!C{d}*CAC_MULT+Channel_Data!K{d}*SALES_COST)",
    }
    for c, v in f.items():
        x = M[f"{c}{r}"]; x.value = v
        if c in "DE": x.fill = INP; x.font = INF; x.border = BOX
        x.number_format = {"B": "$#,##0", "C": "$#,##0", "D": "$#,##0", "E": "$#,##0", "F": "$#,##0", "G": "$#,##0", "H": "$#,##0", "I": "#,##0.0",
                           "J": "$#,##0.0", "K": "0.00%", "L": "$#,##0", "M": "0.00", "N": "0.0", "O": "$#,##0", "P": "$#,##0", "Q": "$#,##0", "R": "$#,##0", "T": "0.00"}.get(c, "General")
r = 9; M[f"A{r}"] = "Total"; M[f"A{r}"].font = B
for c in "BCDEFIPQR": M[f"{c}{r}"] = f"=SUM({c}5:{c}8)"; M[f"{c}{r}"].font = B; M[f"{c}{r}"].number_format = "$#,##0" if c != "I" else "#,##0.0"
M["M9"] = "=P9/Q9"; M["M9"].number_format = "0.00"; M["M9"].font = B
M["A11"] = "Budget check (selected plan allocation - budget):"; M["F11"] = "=F9-BUDGET"; M["F11"].number_format = "$#,##0"
M["A12"] = "Note: Call uses average 2025 economics (col T), so it does not flip with the size of the test; col M shows the marginal ratio at the selected allocation."
M["A13"] = "Note: review_site's blended LTV:CAC hides that 62% of its customers are sales-assisted; self-serve-only LTV:CAC is on Channel_Data col P."
green, amber, red = PatternFill("solid", fgColor="C6EFCE"), PatternFill("solid", fgColor="FFEB9C"), PatternFill("solid", fgColor="FFC7CE")
for t, fl in (("Scale", green), ("Hold", amber), ("Cut", red)):
    M.conditional_formatting.add("S5:S8", CellIsRule(operator="equal", formula=[f'"{t}"'], fill=fl))
M.conditional_formatting.add("F11", CellIsRule(operator="notEqual", formula=["0"], fill=red))

# ---------------- Plan_Compare (all three plans side by side, selected scenario) ----------------
P = wb.create_sheet("Plan_Compare"); P["A1"] = "All plans under the selected scenario"; P["A1"].font = Font(bold=True, size=14)
hdr(P, 3, ["Plan", "Allocated", "New customers", "Total LTV", "Total cost", "Net value", "Value per $ (LTV / cost)", "Budget check"])
for k, (pl, col) in enumerate((("Current mix", "C"), ("Recommended", "D"), ("Custom", "E"))):
    r = 4 + k; P[f"A{r}"] = pl
    alloc = f"Model!{col}5:{col}8"
    cac = f"(Channel_Data!C2:C5*CAC_MULT*(1+ELAST*{alloc}/Model!B5:B8))"
    P[f"B{r}"] = f"=SUM({alloc})"
    P[f"C{r}"] = f"=SUMPRODUCT({alloc}/{cac})"
    P[f"D{r}"] = f"=SUMPRODUCT({alloc}/{cac},Model!L5:L8)"
    P[f"E{r}"] = f"=B{r}+SUMPRODUCT({alloc}/{cac},Channel_Data!K2:K5)*SALES_COST"
    P[f"F{r}"] = f"=D{r}-E{r}"; P[f"G{r}"] = f"=IF(E{r}=0,0,D{r}/E{r})"; P[f"H{r}"] = f"=B{r}-BUDGET"
    for c, fm in zip("BCDEFGH", ["$#,##0", "#,##0.0", "$#,##0", "$#,##0", "$#,##0", "0.00", "$#,##0"]): P[f"{c}{r}"].number_format = fm
P["A8"] = "Custom plan is 0 until you type allocations on Model!E5:E8. Value per $ uses LTV (gross-margin) over marketing + sales cost."
for j, w in enumerate([16, 13, 14, 14, 14, 14, 16, 13]): P.column_dimensions[L(j + 1)].width = w

# ---------------- Sensitivity grid: LTV:CAC by CAC multiplier x GM (paid_search & review_site) ----------------
S = wb.create_sheet("Sensitivity"); S["A1"] = "Avg 2025 fully loaded LTV:CAC under other CAC multipliers and gross margins (live formulas, other levers = active scenario)"
S["A1"].font = B
gms = [0.70, 0.75, 0.80, 0.85]; mults = [0.8, 1.0, 1.2, 1.4]
for b, ch_i in enumerate(range(4)):
    r0 = 3 + b * 7; d = 2 + ch_i
    S.cell(r0, 1, f"=Channel_Data!A{d}").font = B; S.cell(r0, 2, "GM ->")
    for j, g in enumerate(gms): S.cell(r0, 3 + j, g).number_format = "0%"
    for i, m in enumerate(mults):
        S.cell(r0 + 1 + i, 1, "CAC x"); S.cell(r0 + 1 + i, 2, m)
        for j in range(4):
            g = f"{L(3 + j)}${r0}"; mm = f"$B{r0 + 1 + i}"
            arpa = f"Channel_Data!$H${d}*(1+COUPON_FLAG*Channel_Data!$L${d})"
            ch = f"(IF(CHURN_BASIS=1,Channel_Data!$J${d},Channel_Data!$I${d})*CHURN_MULT)"
            x = S.cell(r0 + 1 + i, 3 + j, f"={arpa}*{g}*(1-(1-{ch})^HORIZON)/{ch}/(Channel_Data!$C${d}*{mm}+Channel_Data!$K${d}*SALES_COST)")
            x.number_format = "0.00"
    S.conditional_formatting.add(f"C{r0+1}:F{r0+4}", CellIsRule(operator="lessThan", formula=["1.5"], fill=red))
    S.conditional_formatting.add(f"C{r0+1}:F{r0+4}", CellIsRule(operator="greaterThanOrEqual", formula=["3"], fill=green))
from openpyxl.workbook.properties import CalcProperties; wb.calculation = CalcProperties(fullCalcOnLoad=True)
wb.save("excel/flowdesk_budget_model.xlsx"); print("saved")
