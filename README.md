# ALU Functional Coverage Testbench — VLSI Design Verification

**Course:** VLSI Design Verification  
**University:** An-Najah National University — Computer Engineering Department  
**Assignment:** Final Assignment: Functional Coverage  

---

## Overview

This project implements a **constraint-random SystemVerilog testbench** for a 32×32→64-bit signed ALU. It demonstrates a complete UVM-style verification environment with functional coverage, a scoreboard (checker), and a structured three-class stimulus pipeline.

The testbench verifies the following ALU operations:

| Opcode | Operation |
|--------|-----------|
| `ADD`  | Signed 32-bit addition → 64-bit result |
| `SUB`  | Signed 32-bit subtraction → 64-bit result |
| `MULT` | Signed 32-bit multiplication → 64-bit result |
| `DIV`  | Signed 32-bit division → 64-bit result (0 on divide-by-zero) |

---

## Architecture

The testbench follows a layered, object-oriented verification architecture:

```
┌─────────────┐     mailbox      ┌─────────────┐
│  Generator  │ ───────────────► │   Driver    │
└─────────────┘   (Transaction)  └──────┬──────┘
                                        │ drives
                                 ┌──────▼──────┐
                                 │  DUT (ALU)  │
                                 └──────┬──────┘
                                        │ observes
                                 ┌──────▼──────┐     mailbox      ┌─────────────┐
                                 │   Monitor   │ ───────────────► │ Scoreboard  │
                                 └─────────────┘   (SampleItem)   └─────────────┘
                                        │
                                 ┌──────▼──────┐
                                 │  Coverage   │
                                 │  (CG in     │
                                 │   Monitor)  │
                                 └─────────────┘
```

### Components

- **Transaction** — Randomized stimulus object: `opcode`, `operand1`, `operand2`
- **Generator** — Produces N randomized transactions and pushes them to the driver via mailbox
- **Driver** — Receives transactions and drives the ALU interface on every clock edge
- **Monitor** — Samples the interface after each clock, packages results into `SampleItem`, forwards to scoreboard, and samples the functional coverage covergroup
- **Scoreboard** — Computes expected results using a reference model and compares against DUT output; reports PASS/FAIL per transaction and a final summary
- **Environment** — Top-level container that builds and connects all components; runs them in parallel using `fork...join`

---

## Functional Coverage

The covergroup is defined inside the `Monitor` class and auto-sampled on `posedge clk`.

| Coverpoint | What It Measures |
|---|---|
| `opcodes_cp` | All 4 opcodes hit individually (ADD, SUB, MULT, DIV) |
| `operand1_cp` | Special operand1 values: max negative, zero, max positive, other |
| `opcodes_adv_cp` | Opcode groupings and transitions (ADD→SUB sequence) |
| `div_by_zero_cp` | Division by zero corner case |
| `op_x_operand1_cp` | Cross coverage: every opcode × every operand1 category |

---

## Files

| File | Description |
|------|-------------|
| `alu_tb.sv` | Complete testbench source (DUT + TB environment) |

---

## How to Run

### Using VCS (Synopsys)

```bash
# Compile
vlogan alu_tb.sv -sverilog

# Elaborate and simulate
vcs tb_top -sv

# Run
./simv
```

### Using ModelSim / QuestaSim

```bash
vlog alu_tb.sv
vsim -c tb_top -do "run -all; quit"
```

---

## Sample Output

```
PART1 SUMMARY: PASS=1000 FAIL=0
✓ PART1 OK

---- FUNCTIONAL COVERAGE ----
TOTAL CG             = 100.00%
opcodes_cp           = 100.00%
operand1_cp          = 100.00%
opcodes_adv_cp       = 100.00%
div_by_zero_cp       = 100.00%
op_x_operand1_cp     = 100.00%
```

---

## Key Design Decisions

- **No hardcoded values** — all stimulus is generated via `tr.randomize()` with no directed test cases
- **Reference model** — the scoreboard independently computes expected results using sign-extended arithmetic to match the DUT behavior exactly
- **Divide-by-zero safety** — both DUT and reference model return `64'd0` when dividing by zero, and this corner case is explicitly tracked in coverage
- **1 GHz clock** — 0.5 ns half-period; `#0` delay after clock edge lets combinational logic settle before sampling

---

## Author

**[Your Name]**  
Computer Engineering — An-Najah National University
