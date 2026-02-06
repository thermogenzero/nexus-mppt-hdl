# nexus-mppt-hdl

**Nexus 40K MPPT Controller** - 108-channel thermoelectric optimization with estream PoVC integration.

## Overview

nexus-mppt-hdl is the next-generation FPGA-based Maximum Power Point Tracking (MPPT) controller for large-scale thermoelectric generator (TEG) arrays. Built on the Lattice Nexus 40K FPGA, it consolidates 3× legacy TEG-Opti boards into a single high-density module with native estream platform integration.

## Key Features

- **108 Independent MPPT Channels** - 3× density vs legacy 36-channel TEG-Opti
- **Hardware PoVC Attestation** - Built-in witness generation for carbon credit verification
- **estream Native Protocol** - Direct platform integration (no serial bridge)
- **Remote Bitstream Updates** - Secure OTA with ML-DSA-87 signing, governance threshold, and watchdog failback
- **Post-Quantum Security** - ML-DSA-87 signatures + ML-KEM-1024 encryption (inherited from estream platform)
- **High Availability** - Node failover and HAS offline buffering for 30+ day outages
- **66% Board Count Reduction** - 19 nodes vs 56 boards per 10 kW system

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    NEXUS-MPPT-HDL ARCHITECTURE                           │
│                                                                          │
│   TEG Array (108 TEGs) ──────┐                                          │
│                               ▼                                          │
│   ┌────────────────────────────────────────────────────────────────┐    │
│   │                    Nexus 40K FPGA                               │    │
│   │                                                                 │    │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │    │
│   │  │    MPPT      │  │    PoVC      │  │   estream    │         │    │
│   │  │  108 channel │  │   Witness    │  │   Protocol   │         │    │
│   │  │  Perturb &   │  │  Generation  │  │   Native     │         │    │
│   │  │  Observe     │  │  Merkle Tree │  │              │         │    │
│   │  └──────────────┘  └──────────────┘  └──────┬───────┘         │    │
│   │         │                │                   │                 │    │
│   │  ┌──────┴────────────────┴───────────────────┴──────────────┐ │    │
│   │  │              PWM Controller (108 Channels)                │ │    │
│   │  │              ADC Controller (9× ADS7950)                  │ │    │
│   │  └──────────────────────────────────────────────────────────┘ │    │
│   │                                                                 │    │
│   │  ┌──────────────────────────────────────────────────────────┐ │    │
│   │  │              Remote Update Engine                         │ │    │
│   │  │              ML-DSA-87 sign, ML-KEM-1024, Governance k/n  │ │    │
│   │  │              Dual-slot flash, FRAM inventory, Watchdog    │ │    │
│   │  └──────────────────────────────────────────────────────────┘ │    │
│   │                                                                 │    │
│   └───────────────────────────────────────────────────────────────┘│    │
│                               │ Ethernet                            │    │
│                               ▼                                      │    │
│   ┌────────────────────────────────────────────────────────────────┐│    │
│   │              estream Node (T0 or Dev Hardware)                  ││    │
│   └────────────────────────────────────────────────────────────────┘│    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Repository Structure

```
nexus-mppt-hdl/
├── rtl/                         # Verilog RTL source
│   ├── mppt/                   # MPPT controller (108-channel)
│   │   ├── mppt_core.v         # Perturb & Observe algorithm
│   │   ├── mppt_channel.v      # Per-channel state machine
│   │   └── mppt_aggregator.v   # Multi-channel coordination
│   ├── adc/                    # ADC interface (9× ADS7950)
│   │   ├── ads7950_driver.v    # SPI driver
│   │   └── ads7950_phy.v       # Physical layer
│   ├── pwm/                    # PWM generation
│   │   └── pwm_108ch.v         # 108-channel PWM controller
│   ├── povc/                   # PoVC witness generation
│   │   ├── merkle_witness.v    # Merkle tree construction
│   │   ├── povc_generator.v    # 64-bit witness generation
│   │   └── prime_signer.v      # Hardware attestation
│   ├── estream/                # estream protocol
│   │   ├── wire_encoder.v      # Wire protocol framing
│   │   ├── stream_emitter.v    # Telemetry stream
│   │   └── discovery.v         # Node auto-registration
│   ├── update/                 # Remote bitstream update (from estream marketplace)
│   │   ├── bitstream_rx.v      # Receive state machine
│   │   ├── flash_manager.v     # Dual-slot + FRAM inventory management
│   │   ├── ml_dsa87_verify.v   # ML-DSA-87 post-quantum signature verification
│   │   ├── governance.v        # k-of-n threshold approval
│   │   └── watchdog.v          # Failback watchdog with monotonic rollback
│   └── safety/                 # Safety systems
│       ├── overvoltage.v       # 58V bus protection
│       └── ground_fault.v      # Ground fault detection
├── tb/                          # Testbenches
│   ├── mppt_tb.v               # MPPT algorithm tests
│   ├── povc_tb.v               # PoVC witness tests
│   └── system_tb.v             # Full system simulation
├── constraints/                 # FPGA constraints
│   └── nexus40k.lpf            # Pin assignments
├── scripts/                     # Build scripts
│   ├── build.tcl               # Synthesis script
│   └── program.py              # Programming utility
├── docs/                        # Documentation
│   ├── SPECIFICATION.md        # Full technical spec
│   ├── MIGRATION.md            # TEG-Opti migration guide
│   └── PINOUT.md               # Hardware pinout
└── pcb/                         # PCB design files
    ├── schematics/             # Schematic PDFs
    └── gerber/                 # Manufacturing files
```

## Comparison: TEG-Opti vs Nexus-MPPT

| Specification | TEG-Opti (Legacy) | Nexus-MPPT |
|---------------|-------------------|------------|
| FPGA | iCE40 HX8K | Nexus 40K |
| Channels | 36 | 108 (3×) |
| PoVC | Not available | Built-in witness |
| Protocol | BFST serial | estream native |
| Remote Update | Hardware only | Full implementation |
| Boards per 10 kW | 56 + controller | 19 nodes |
| Security | None | ML-DSA-87 + ML-KEM-1024 + attestation |
| Offline | None | HAS buffering (30+ days) |
| Availability | Single node | HA failover (active/passive) |

## Implementation Timeline

| Phase | Timeline | Deliverable |
|-------|----------|-------------|
| Phase 1 | Q1 2026 | Remote bitstream update integration |
| Phase 2 | Q1-Q2 2026 | PoVC witness integration |
| Phase 3 | Q2-Q3 2026 | estream protocol native |
| Phase 4 | Q3-Q4 2026 | Nexus 40K 108-channel port |
| Phase 5 | Q4 2026 | Operations console + SCADA |

## estream Marketplace Components

This project leverages estream marketplace components (free via early adopter program):

| Component | SKU | Status | Upstream Implementation |
|-----------|-----|--------|------------------------|
| PoVC Witness Generation | `teg-opti-povc-witness` | Available | ESCIR circuits (4 types), VRF selector RTL |
| Remote Bitstream Update | `teg-opti-remote-update` | Available | `t0_bitstream_manager.v` (831 lines), deployment framework |
| Nexus 40K Integration | `nexus-40k-integration` | Available | Witness aggregation circuits, NTT engines |
| Industrial Gateway | `industrial-gateway-standard` | Available | `estream-industrial` crate, V2 layered architecture |

### Additional Platform Features Available

| Feature | Implementation | Usage |
|---------|---------------|-------|
| Node HA Engine | `fpga/rtl/ha/node_ha_engine.v` | Active/passive failover for critical infrastructure |
| HAS Offline Engine | `fpga/rtl/has/has_offline_engine.v` | 30+ day offline buffering with auto-resync |
| Wire Protocol | `crates/estream-wire/` | UDP binary protocol (1-5us latency), magic `0x45535452` |
| Deployment Framework | `crates/estream-deployment/` | Canary, staged, rolling, blue-green strategies |
| Tenant FPGA Isolation | `fpga/rtl/isolation/` | Hardware-enforced isolation with TLA+ verification |
| StreamSight | `fpga/rtl/streamsight/` | Real-time observability and alerting |

## Building

```bash
# Synthesis (requires Lattice Radiant)
make synthesis

# Place & Route
make pnr

# Generate bitstream
make bitstream

# Program device
make program
```

## Testing

```bash
# Run all testbenches
make test

# Run specific test
make test-mppt
make test-povc
```

## Related Repositories

### New Architecture (Clean Names)
- [thermogenzero/node-hdl](https://github.com/thermogenzero/node-hdl) - **Successor to this repo** - Controller Node firmware
- [thermogenzero/node](https://github.com/thermogenzero/node) - Controller Node hardware (LIFCL-40/LFCPNX-100 board)
- [thermogenzero/pcm](https://github.com/thermogenzero/pcm) - Power Conversion Module hardware (buck + ADC + iCE40)
- [thermogenzero/pcm-hdl](https://github.com/thermogenzero/pcm-hdl) - PCM iCE40 firmware (SPI slave, ADC driver, PWM)

### Legacy (Being Superseded)
- [thermogenzero/nexus-mppt-hardware](https://github.com/thermogenzero/nexus-mppt-hardware) - Original FPGA node board (-> node)
- [thermogenzero/teg-pcb](https://github.com/thermogenzero/teg-pcb) - Original TEG PCB (-> pcm)
- [thermogenzero/teg-opti-hdl](https://github.com/thermogenzero/teg-opti-hdl) - Legacy 36-channel controller (-> pcm-hdl)
- [thermogenzero/teg-opti-hardware](https://github.com/thermogenzero/teg-opti-hardware) - Legacy TEG-Opti board

### Ecosystem
- [synergycarbon/povc-carbon](https://github.com/synergycarbon/povc-carbon) - Carbon credit minting (consumes PoVC)
- [synergythermogen/ip](https://github.com/synergythermogen/ip) - IP and patent portfolio

## License

Proprietary - Thermogen Zero, Inc.  
Commercial rights held via ICA agreement.

## Contact

- Engineering: engineering@thermogenzero.com
- Hardware: hardware@thermogenzero.com
