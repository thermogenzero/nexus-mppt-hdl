# estream Platform Contributions

**Last Updated:** February 6, 2026  
**Status:** Early Adopter Program

This document tracks the estream platform features consumed by Thermogen Zero and contributions back to the platform.

---

## Implementation Impact

### Timeline Reduction: 50%

| Metric | Original Estimate | Revised Estimate | Savings |
|--------|-------------------|------------------|---------|
| Total Duration | 54-74 weeks | 27-38 weeks | **50%** |
| Engineering Cost | ~$270K-370K | ~$135K-190K | **~$180K** |

### Cost Savings from Marketplace Components + Platform Features

| Component | Build Cost (Original) | Marketplace Cost | Savings |
|-----------|----------------------|------------------|---------|
| Remote Bitstream Update (PQ crypto) | ~$60K (10-14 wks) | $0 (early adopter) | **$60K** |
| PoVC Witness Generation | ~$75K (10-14 wks) | $0 (early adopter) | **$75K** |
| Nexus 40K Integration | ~$100K (16-20 wks) | $0 (early adopter) | **$100K** |
| Industrial Gateway V2 | ~$40K (custom) | $0 (early adopter) | **$40K** |
| Node HA Engine | ~$25K (4-6 wks) | $0 (platform) | **$25K** |
| HAS Offline Engine | ~$20K (3-5 wks) | $0 (platform) | **$20K** |
| Wire Protocol | ~$15K (2-4 wks) | $0 (platform) | **$15K** |
| Witness ESCIR Circuits | ~$20K (3-5 wks) | $0 (platform) | **$20K** |
| **Total** | **~$355K** | **$0** | **$355K** |

*Estimates based on $5K/week engineering cost. Updated to reflect post-quantum crypto upgrade (ML-DSA-87 vs Ed25519) and additional platform features.*

---

## Platform Features Consumed

### Deployment Framework (Features 4, 5)

**Status:** ✅ Implemented - Ready to Use

| Component | Implementation | Usage |
|-----------|----------------|-------|
| DeploymentManager | `crates/estream-deployment/` | Artifact deployment |
| NetworkManager | `crates/estream-deployment/src/network.rs` | Fleet management |
| Strategies | AllAtOnce, Rolling, BlueGreen, Canary, Staged | Safe rollouts |
| DeltaEngine | `crates/estream-deployment/src/delta.rs` | Differential updates |

**How We Use It:**
```rust
use estream_deployment::{DeploymentManager, Strategy, NetworkManager};

// Canary deployment for safe bitstream rollouts
let manager = DeploymentManager::new();
let deployment = manager.create_deployment(
    bitstream_artifact,
    Strategy::Canary { initial_percent: 10 },
);

// Multi-node fleet deployment
let fleet = NetworkManager::new();
fleet.register_node(wellpad_node_config);
fleet.deploy(deployment_id).await?;
```

### Tenant FPGA Isolation (Feature 6)

**Status:** ✅ Implemented - Ready to Use

| Component | Implementation | Usage |
|-----------|----------------|-------|
| IsolationAttestation | `crates/estream-kernel/src/consensus/isolation_attestation.rs` | Hardware attestation |
| QuotaEnforcer | `crates/estream-kernel/src/consensus/quota_enforcer.rs` | Resource limits |
| TimingMitigation | `crates/estream-kernel/src/consensus/timing_mitigation.rs` | Side-channel protection |
| Hardware RTL | `fpga/rtl/isolation/quota_enforcer.v` | FPGA enforcement |
| TLA+ Spec | `specs/isolation/TenantIsolation.tla` | Formal verification |

**How We Use It:**
```rust
use estream_kernel::consensus::{IsolationAttestation, QuotaEnforcer, TenantQuota};

// Configure tenant isolation for TEG-Opti modules
let mut enforcer = QuotaEnforcer::new();
enforcer.register_tenant(TenantQuota {
    tenant_id: "thermogenzero-teg-opti",
    lut_limit: 15000,
    bram_limit: 32,
    // ...
});

// Generate attestation for each MPPT cycle
let attestation = IsolationAttestation::generate(&partition, &signer)?;
```

### Industrial Gateway V2 (Feature 1)

**Status:** ✅ Implemented - Marketplace #424 (V2 Layered Architecture)

The upstream `crates/estream-industrial/` crate provides a complete implementation with layered composable architecture:

| Protocol | Support | Crate Feature | Usage |
|----------|---------|---------------|-------|
| MODBUS TCP | ✅ | `modbus-tcp` (default) | SCADA integration |
| MODBUS RTU | ✅ | `modbus-rtu` | Legacy devices |
| OPC-UA | ✅ | `opcua` | Modern SCADA |
| DNP3 | ✅ | `dnp3` | Utility SCADA |

**Marketplace Tiers:**

| Tier | SKU | Protocols | Price |
|------|-----|-----------|-------|
| Lite | `industrial-gateway-lite` | MODBUS TCP only | Free (Apache-2.0) |
| Standard | `industrial-gateway-standard` | TCP + RTU + OPC-UA | 100 ES/mo ($0 early adopter) |
| Premium | `industrial-gateway-premium` | Standard + DNP3, NERC-CIP | 300 ES/mo |

**V2 Architecture:** Transport layer (TCP, Serial, UDP) + Protocol layer (MODBUS, OPC-UA, DNP3 as ESF schemas) + StreamSight integration. ESCIR circuit definitions available at `circuits/industrial/`.

**How We Use It:**
```yaml
# Industrial Gateway configuration
gateway:
  id: teg-opti-scada-bridge
  protocols:
    - modbus_tcp:
        port: 502
        registers:
          - address: 0x0000
            name: power_output_watts
            type: uint32
            access: read
          - address: 0x0004
            name: bus_voltage
            type: uint16
            access: read
    - modbus_rtu:
        device: /dev/ttyUSB0
        baud: 9600
```

### Node High Availability (Feature 5)

**Status:** ✅ Implemented - Ready to Use

Addresses upstream Feature Request #5 (Redundant Node Failover). Critical for wellpad deployments where infrastructure requires 99.99% uptime.

| Component | Implementation | Usage |
|-----------|----------------|-------|
| Node HA Engine | `fpga/rtl/ha/node_ha_engine.v` | Active/passive failover |
| HA Crate | `crates/estream-ha/` | State synchronization, split-brain prevention |

**How We Use It:** Each wellpad estream Node can run in active/passive mode with automatic failover on heartbeat loss. State synchronization ensures consistent lex views across nodes.

### HAS Offline Engine (Feature 2)

**Status:** ✅ Implemented - Ready to Use

Addresses upstream Feature Request #2 (Offline Operation). Essential for remote wellpads with intermittent Starlink/cellular connectivity.

| Component | Implementation | Usage |
|-----------|----------------|-------|
| HAS Offline Engine | `fpga/rtl/has/has_offline_engine.v` | Hardware-attested offline buffering |
| HAS Offline Crate | `crates/estream-has-offline/` | 30+ day offline operation |

**How We Use It:** TEG-Opti nodes continue generating PoVC-attested telemetry during network outages. On reconnect, buffered data auto-syncs with conflict resolution and compressed batch upload.

### Wire Protocol (Phase 3 Foundation)

**Status:** ✅ Implemented - Ready to Use

Fully implemented estream wire protocol that forms the basis for Phase 3 (estream Protocol Native).

| Component | Implementation | Usage |
|-----------|----------------|-------|
| Wire Protocol | `crates/estream-wire/` | UDP binary protocol |
| Magic | `0x45535452` ("ESTR") | Frame identification |
| Packet Types | `0x01-0x8F` ranges | Full protocol coverage |
| Witness Messages | `0x80-0x8F` | PoVC attestation wire format |

**Performance:** 1-5us latency (UDP) vs 50-500us (TCP). FPGA-optimized for direct hardware integration.

### Witness ESCIR Circuits (Phase 2 Foundation)

**Status:** ✅ Implemented - Ready to Use

Four ESCIR circuit definitions for witness generation and verification, providing the framework for Phase 2 (PoVC Integration).

| Circuit | Version | Est. LUTs | Usage |
|---------|---------|-----------|-------|
| `vrf-output-hash` | v0.5.0 | ~5,000 | SHA3-256 VRF output computation |
| `vrf-threshold-check` | v0.5.0 | ~100 | Witness selection qualification |
| `witness-aggregator` | v0.5.0 | ~120 | Multi-tier attestation aggregation |
| `witness-selection` | v0.5.0, v0.8.0 | ~250-3,000 | VRF-based witness selection with stake weighting |

**Supporting RTL:**
- `fpga/rtl/crypto/vrf_selector.v` - VRF-based witness selection
- `fpga/rtl/crypto/vrf_evaluator.v` - VRF evaluation engine
- `fpga/rtl/iso20022/povc_witness_gen.v` - Reference PoVC witness generation
- `fpga/rtl/crypto/prime_signer.v` - Hardware attestation signing

---

## Marketplace Components (Early Adopter - FREE)

### TEG-Opti PoVC Witness
- **SKU:** `teg-opti-povc-witness`
- **Normal Price:** 150 ES/mo
- **Early Adopter Price:** $0 (24 months)
- **Contents:**
  - `fpga/rtl/thermogen/merkle_witness.v`
  - `fpga/rtl/thermogen/povc_generator.v`
  - `fpga/rtl/crypto/prime_signer.v`

### Remote Bitstream Update
- **SKU:** `teg-opti-remote-update`
- **Normal Price:** 100 ES/mo
- **Early Adopter Price:** $0 (24 months)
- **Upstream Reference:** `fpga/rtl/prime/t0_bitstream_manager.v` (831 lines)
- **Contents:**
  - `fpga/rtl/update/bitstream_rx.v` - Receive state machine
  - `fpga/rtl/update/flash_manager.v` - Dual-slot + FRAM inventory (64 bitstreams, 4MB each)
  - `fpga/rtl/update/ml_dsa87_verify.v` - ML-DSA-87 post-quantum signature verification
  - `fpga/rtl/update/governance.v` - k-of-n threshold approval (configurable, default 5-of-9)
  - `fpga/rtl/update/watchdog.v` - Failback watchdog with monotonic rollback protection
- **Security:** ML-DSA-87 signing (4627-byte signatures) + ML-KEM-1024 session key encryption
- **Deployment:** Integrates with `estream-deployment` canary/staged rollout strategies

### Nexus 40K Integration
- **SKU:** `nexus-40k-integration`
- **Normal Price:** 200 ES/mo
- **Early Adopter Price:** $0 (24 months)
- **Contents:**
  - `fpga/rtl/thermogen/mppt_108ch.v`
  - `fpga/rtl/thermogen/witness_aggregator.v`
  - Nexus 40K-specific optimizations

### Industrial Gateway Standard
- **SKU:** `industrial-gateway-standard`
- **Normal Price:** 100 ES/mo
- **Early Adopter Price:** $0 (24 months)
- **Contents:**
  - MODBUS TCP/RTU bridge
  - OPC-UA client
  - StreamSight telemetry integration

---

## Early Adopter Program Benefits

| Benefit | Details |
|---------|---------|
| Free Marketplace Access | All 4 components at $0 for 24 months |
| Full Source Code | Verilog RTL (not compiled bitstreams) |
| Priority Support | Direct engineering support channel |
| Roadmap Input | Direct input on platform features |
| Custom Pricing Lock | Rates locked for 24 months |
| Case Study | Marketing collaboration opportunity |

---

## Risk Reduction via Platform

| Risk | Original Level | With Platform | Impact |
|------|----------------|---------------|--------|
| ML-DSA-87 Verilog core | HIGH (needed) | LOW (in marketplace) | Eliminated |
| Fleet management complexity | HIGH (custom) | LOW (NetworkManager) | Eliminated |
| Tenant isolation security | HIGH (custom) | LOW (TLA+ verified) | Eliminated |
| SCADA integration | MEDIUM (custom) | LOW (V2 layered gateway) | Eliminated |
| Remote update reliability | HIGH (custom) | LOW (831-line proven RTL) | Eliminated |
| Node failover / uptime | HIGH (custom HA) | LOW (node_ha_engine.v) | Eliminated |
| Offline operation (30+ days) | HIGH (custom) | LOW (has_offline_engine.v) | Eliminated |
| Wire protocol implementation | MEDIUM (custom) | LOW (estream-wire crate) | Eliminated |
| Witness framework | HIGH (custom crypto) | LOW (4 ESCIR circuits + VRF RTL) | Eliminated |

---

## Related Documentation

- [estream-io Platform SDK](https://docs.estream.io/sdk)
- [Deployment Framework Guide](https://docs.estream.io/deployment)
- [Industrial IoT Client Architecture](https://docs.estream.io/industrial-iot)
- [Tenant Isolation Specification](https://docs.estream.io/isolation)
- [Wire Protocol Specification](https://docs.estream.io/wire-protocol)
- [PoVC Witness Framework](https://docs.estream.io/witness)
- [High Availability Guide](https://docs.estream.io/ha)
- [HAS Offline Operation](https://docs.estream.io/has-offline)

## Contact

- **estream Support:** support@estream.io
- **Thermogen Zero Engineering:** engineering@thermogenzero.com
