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

### Cost Savings from Marketplace Components

| Component | Build Cost (Original) | Marketplace Cost | Savings |
|-----------|----------------------|------------------|---------|
| Remote Bitstream Update | ~$50K (8-12 wks) | $0 (early adopter) | **$50K** |
| PoVC Witness Generation | ~$75K (10-14 wks) | $0 (early adopter) | **$75K** |
| Nexus 40K Integration | ~$100K (16-20 wks) | $0 (early adopter) | **$100K** |
| Industrial Gateway | ~$30K (custom) | $0 (early adopter) | **$30K** |
| **Total** | **~$255K** | **$0** | **$255K** |

*Estimates based on $5K/week engineering cost*

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

### Industrial Gateway (Feature 1)

**Status:** ✅ Available - Marketplace #424

| Protocol | Support | Usage |
|----------|---------|-------|
| MODBUS TCP | ✅ | SCADA integration |
| MODBUS RTU | ✅ | Legacy devices |
| OPC-UA | ✅ | Modern SCADA |

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
- **Contents:**
  - `fpga/rtl/update/bitstream_rx.v`
  - `fpga/rtl/update/flash_manager.v`
  - `fpga/rtl/update/ed25519_verify.v`
  - `fpga/rtl/update/watchdog.v`

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
| SCADA integration | MEDIUM (custom) | LOW (marketplace) | Eliminated |
| Remote update reliability | HIGH (custom) | LOW (proven RTL) | Eliminated |

---

## Related Documentation

- [estream-io Platform SDK](https://docs.estream.io/sdk)
- [Deployment Framework Guide](https://docs.estream.io/deployment)
- [Industrial IoT Client Architecture](https://docs.estream.io/industrial-iot)
- [Tenant Isolation Specification](https://docs.estream.io/isolation)

## Contact

- **estream Support:** support@estream.io
- **Thermogen Zero Engineering:** engineering@thermogenzero.com
