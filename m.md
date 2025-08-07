# Complete NLB Bypass Migration Flow

This diagram shows the **complete end-to-end flow** of the NLB bypass migration including all validation checks, exit points, DNS operations, and Fastly changes across all scripts.

## Forward Migration Flow (bypass_nlb = true)

```mermaid
flowchart TD
    Start([python migration_bypass_nlb.py cluster.dev true]) --> CheckArgs{Valid Arguments?}
    CheckArgs -->|No| ExitUsage[Exit 1: Usage Error]
    CheckArgs -->|Yes| CheckHiera{HIERA_DIR exists?}
    
    CheckHiera -->|No| ExitHiera[Exit 1: NO_HIERA_DIR]
    CheckHiera -->|Yes| CheckDG3{detect_dg3_cluster<br/>Read topology.yaml}
    
    CheckDG3 -->|dedication=true + squashfs_version| ExitDG3[Exit 1: DG3_CLUSTER_DETECTED]
    CheckDG3 -->|Not DG3| CheckAWS{detect_cluster_provider<br/>Read topology.yaml}
    
    CheckAWS -->|No topology file| ExitTopoMissing[Exit 1: ERROR_NO_TOPOLOGY_FILE]
    CheckAWS -->|No provider field| ExitNoProvider[Exit 1: ERROR_NO_PROVIDER]
    CheckAWS -->|provider != aws| ExitAWS[Exit 1: NOT_AWS_PROJECT]
    CheckAWS -->|provider = aws| PrintAWS[Print: AWS_PROJECT detected]
    
    PrintAWS --> ConvertFormats[Convert cluster formats<br/>DNS ↔ Fastly]
    
    ConvertFormats --> ValidateFastly[fastly_healthcheck.py --keepalive validate]
    ValidateFastly --> FastlyVal1{Get Service ID}
    FastlyVal1 -->|Service not found| ExitServiceNotFound[Exit 1: Fastly Error: Service X not found]
    FastlyVal1 -->|Found| FastlyVal2{Get Active Version}
    
    FastlyVal2 -->|No active version| ExitNoActiveVer[Exit 1: No active version found]
    FastlyVal2 -->|Found| FastlyVal3{Get Backends}
    
    FastlyVal3 -->|No backends| ExitNoBackends[Exit 1: Error: No backends found]
    FastlyVal3 -->|Found| FastlyVal4{Backend hostname matches?<br/>c.cluster.dev.ent.magento.cloud}
    
    FastlyVal4 -->|No match| ExitBackendMismatch[Exit 1: ERROR: No backend found with expected hostname]
    FastlyVal4 -->|Match found| ValidateFastlyPass[Backend validation passed]
    
    ValidateFastlyPass --> Step0[fastly_healthcheck.py --keepalive test]
    
    Step0 --> HC1{Get Service ID}
    HC1 -->|Service not found| ExitHC1[Exit 1: Service not found]
    HC1 -->|Found| HC2{Get Active Version}
    
    HC2 -->|No active version| ExitHC2[Exit 1: No active version]
    HC2 -->|Found| HC3{Get Backend Details}
    
    HC3 -->|No backends| ExitHC3[Exit 1: No backends found]
    HC3 -->|Found| HC4{Extract Backend IPs}
    
    HC4 -->|DNS resolution fails| ExitHC4[Exit 1: ERROR: Could not determine backend IPs]
    HC4 -->|Success| HC5{Get Fastly Domains}
    
    HC5 -->|Error getting domains| HC6[Continue with empty domain list]
    HC5 -->|Success| HC6[Test Each Domain]
    
    HC6 --> HC7{For each domain:<br/>Test with ALL backend IPs}
    HC7 -->|Domain fails with any IP| HC8[Reject domain - FAIL FAST]
    HC7 -->|Domain works with ALL IPs| HC9[Add to working domains]
    
    HC8 --> HC10{Any domains work with ALL IPs?}
    HC10 -->|No working domains| ExitHC10[Exit 1: No working domains found]
    HC10 -->|Has working domains| HC11[Select best domain<br/>Priority: cluster ID match]
    
    HC9 --> HC10
    HC11 --> HCPass[Healthcheck test passed]
    
    HCPass --> Step1[migration_1_build_b_cnames.py]
    
    Step1 --> DNS1{Get Route53 Zone ID<br/>magento.cloud}
    DNS1 -->|Zone not found| ExitDNS1[Exit 1: ERROR: Zone magento.cloud. not found]
    DNS1 -->|Found| DNS2{Resolve Backend IPs<br/>1,2,3.cluster.dev.ent.magento.cloud}
    
    DNS2 -->|Any DNS resolution fails| ExitDNS2[Exit 1: ERROR: Failed to resolve hostname]
    DNS2 -->|All resolved| DNS3[Create Route53 Multivalue A Records<br/>b.cluster.dev.ent.magento.cloud]
    
    DNS3 -->|Route53 API fails| ExitDNS3[Exit 1: Route53 API Error]
    DNS3 -->|Success| Step2[migration_2_bypass_nlb_c_cname.py true]
    
    Step2 --> DNS4{Get Route53 Zone ID}
    DNS4 -->|Zone not found| ExitDNS4[Exit 1: ERROR: Zone magento.cloud. not found]
    DNS4 -->|Found| DNS5{Check existing c.cluster record}
    
    DNS5 -->|API Error| ExitDNS5[Exit 1: ERROR: Failed to get existing record]
    DNS5 -->|Success| DNS6{Verify b record exists}
    
    DNS6 -->|b record missing| ExitDNS6[Exit 1: ERROR: Cannot bypass NLB: b record doesn't exist]
    DNS6 -->|b record exists| DNS7[DELETE existing c record<br/>CREATE new c record → b.cluster.dev]
    
    DNS7 -->|Route53 API fails| ExitDNS7[Exit 1: ERROR: Failed to update DNS]
    DNS7 -->|Success| Step3[fastly_healthcheck.py --keepalive add]
    
    Step3 --> FC1{Get Service ID}
    FC1 -->|Service not found| ExitFC1[Exit 1: Service not found]
    FC1 -->|Found| FC2{Get Active Version}
    
    FC2 -->|No active version| ExitFC2[Exit 1: No active version]
    FC2 -->|Found| FC3{Validate Backend Compatibility}
    
    FC3 -->|Backend mismatch| ExitFC3[Exit 1: Backend validation failed]
    FC3 -->|Valid| FC4{Analyze Backend Configuration}
    
    FC4 -->|No backends| ExitFC4[Exit 1: No backends found]
    FC4 -->|Success| FC5{Extract Backend IPs}
    
    FC5 -->|IP resolution fails| ExitFC5[Exit 1: Could not determine backend IPs]
    FC5 -->|Success| FC6{Test All Domains}
    
    FC6 -->|No working domains| FC7[Use backend hostname as fallback]
    FC6 -->|Has working domains| FC8[Select best working domain]
    
    FC7 --> FC9[Clone Active Version]
    FC8 --> FC9
    
    FC9 -->|Clone fails| ExitFC9[Exit 1: Error cloning version<br/>Read-only token?]
    FC9 -->|Success| FC10[Create Healthcheck Configuration<br/>Name: psh-origin-hc<br/>Path: /psh-nginx-alive/]
    
    FC10 -->|Fastly API fails| ExitFC10[Exit 1: Error creating healthcheck]
    FC10 -->|Success| FC11[Update Backend to use Healthcheck]
    
    FC11 -->|Backend update fails| ExitFC11[Exit 1: Error updating backend]
    FC11 -->|Success| FC12[Activate New Version]
    
    FC12 -->|Activation fails| ExitFC12[Exit 1: Error activating version]
    FC12 -->|Success| Success[🎉 Migration completed successfully!]

    style Success fill:#90EE90
    style ExitDG3 fill:#FFB6C1
    style ExitAWS fill:#FFB6C1
    style ExitHC10 fill:#FFB6C1
```

## Rollback Flow (bypass_nlb = false)

```mermaid
flowchart TD
    StartRB([python migration_bypass_nlb.py cluster.dev false]) --> CheckArgsRB{Valid Arguments?}
    CheckArgsRB -->|No| ExitUsageRB[Exit 1: Usage Error]
    CheckArgsRB -->|Yes| CheckHieraRB{HIERA_DIR exists?}
    
    CheckHieraRB -->|No| ExitHieraRB[Exit 1: NO_HIERA_DIR]
    CheckHieraRB -->|Yes| CheckDG3RB{detect_dg3_cluster}
    
    CheckDG3RB -->|DG3 detected| ExitDG3RB[Exit 1: DG3_CLUSTER_DETECTED]
    CheckDG3RB -->|Not DG3| CheckAWSRB{detect_cluster_provider}
    
    CheckAWSRB -->|Not AWS| ExitAWSRB[Exit 1: NOT_AWS_PROJECT]
    CheckAWSRB -->|AWS| Step2RB[migration_2_bypass_nlb_c_cname.py false]
    
    Step2RB --> DNS1RB{Get Route53 Zone ID}
    DNS1RB -->|Zone not found| ExitDNS1RB[Exit 1: Zone not found]
    DNS1RB -->|Found| DNS2RB{Get NLB DNS Name}
    
    DNS2RB --> RegionRB{detect_cluster_region<br/>Read topology.yaml}
    RegionRB -->|No topology| ExitRegionRB[Exit 1: Could not detect region]
    RegionRB -->|No region field| ExitRegionRB
    RegionRB -->|Region found| DNS3RB{Find NLB in region}
    
    DNS3RB -->|NLB not found| ExitNLBRB[Exit 1: ERROR: Cannot use NLB: NLB not found]
    DNS3RB -->|NLB found| DNS4RB[DELETE existing c record<br/>CREATE new c record → NLB DNS]
    
    DNS4RB -->|Route53 fails| ExitDNS4RB[Exit 1: ERROR: Failed to update DNS]
    DNS4RB -->|Success| Step3RB[fastly_healthcheck.py --keepalive remove]
    
    Step3RB --> FC1RB{Get Service ID}
    FC1RB -->|Not found| ExitFC1RB[Exit 1: Service not found]
    FC1RB -->|Found| FC2RB{Get Active Version}
    
    FC2RB -->|No active version| ExitFC2RB[Exit 1: No active version]
    FC2RB -->|Found| FC3RB{Check for psh-origin-hc}
    
    FC3RB -->|Not found| SkipRemovalRB[Nothing to remove - exit success]
    FC3RB -->|Found| FC4RB[Clone Active Version]
    
    FC4RB -->|Clone fails| ExitFC4RB[Exit 1: Clone failed]
    FC4RB -->|Success| FC5RB[Remove healthcheck from backends]
    
    FC5RB --> FC6RB[Delete psh-origin-hc healthcheck]
    FC6RB --> FC7RB[Activate new version]
    
    FC7RB -->|Activation fails| ExitFC7RB[Exit 1: Activation failed]
    FC7RB -->|Success| SuccessRB[🎉 Rollback completed successfully!]

    style SuccessRB fill:#90EE90
    style SkipRemovalRB fill:#87CEEB
```

## DNS State Changes

### Forward Migration DNS Flow
```mermaid
flowchart LR
    subgraph "Before Migration"
        A1[c.cluster.dev] --> A2[cluster-dev-nlb.elb.region.amazonaws.com]
        A2 --> A3[Backend IPs via NLB]
    end
    
    subgraph "Step 1: Create B Records"
        B1[b.cluster.dev] 
        B2[1.cluster.dev → IP1<br/>2.cluster.dev → IP2<br/>3.cluster.dev → IP3]
        B1 -.-> B2
        B1 --> B3[Multivalue A Records<br/>→ IP1, IP2, IP3]
    end
    
    subgraph "Step 2: Update C Record"
        C1[c.cluster.dev] --> C2[b.cluster.dev.ent.magento.cloud]
        C2 --> C3[Direct to Backend IPs<br/>NLB bypassed]
    end
    
    A1 -.->|Migration| C1
```

### Rollback DNS Flow
```mermaid
flowchart LR
    subgraph "During Bypass"
        A1[c.cluster.dev] --> A2[b.cluster.dev.ent.magento.cloud]
        A2 --> A3[Direct Backend IPs]
    end
    
    subgraph "Rollback: Restore C Record"
        B1[c.cluster.dev] --> B2[cluster-dev-nlb.elb.region.amazonaws.com]
        B2 --> B3[Backend IPs via NLB]
        B4[b.cluster.dev] -.->|Orphaned| B5[Multivalue A Records<br/>Not cleaned up]
    end
    
    A1 -.->|Rollback| B1
```

## Fastly Healthcheck Configuration

### Forward: Add Healthcheck
```mermaid
flowchart TD
    A[Select Domain from working domains] --> B{Domain Selection Priority}
    B --> C[1. Domain with cluster ID + ALL IPs working]
    B --> D[2. Any domain with ALL IPs working]
    C --> E[Create psh-origin-hc]
    D --> E
    
    E --> F[Healthcheck Config:<br/>Host: selected.domain.com<br/>Path: /psh-nginx-alive/<br/>Method: HEAD<br/>HTTP/1.0<br/>Interval: 15s<br/>Timeout: 5s<br/>Expected: 200]
    
    F --> G[Update Backend:<br/>backend.healthcheck = psh-origin-hc]
    G --> H[Activate Version]
```

### Rollback: Remove Healthcheck
```mermaid
flowchart TD
    A[Check for psh-origin-hc] --> B{Exists?}
    B -->|No| C[Nothing to remove]
    B -->|Yes| D[Remove from backends:<br/>backend.healthcheck = ""]
    D --> E[Delete psh-origin-hc]
    E --> F[Activate Version]
```

## All Exit Points and Error Messages

| Exit Point | Script | Error Message | Tracked by report2.py |
|------------|---------|---------------|----------------------|
| **DG3 Detection** | migration_bypass_nlb.py | `DG3_CLUSTER_DETECTED` | ✅ DG3_CLUSTER_DETECTED |
| **Not AWS** | migration_bypass_nlb.py | `NOT_AWS_PROJECT` | ✅ NOT_AWS_PROJECT |
| **No Topology** | migration_bypass_nlb.py | `ERROR_NO_TOPOLOGY_FILE` | ✅ ERROR_NO_TOPOLOGY_FILE |
| **No Provider** | migration_bypass_nlb.py | `ERROR_NO_PROVIDER` | ✅ ERROR_NO_PROVIDER |
| **Service Not Found** | fastly_healthcheck.py | `❌ Fastly Error: Service 'X' not found` | ✅ SERVICE_NOT_FOUND |
| **No Active Version** | fastly_healthcheck.py | `❌ Fastly Error: No active version found for service` | ✅ NO_ACTIVE_VERSION |
| **Backend Mismatch** | fastly_healthcheck.py | `ERROR: No backend found with expected hostname` | ✅ BACKEND_NOT_FOUND |
| **No Backend IPs** | fastly_healthcheck.py | `ERROR: Could not determine backend IPs` | ✅ BACKEND_UNRESOLVABLE |
| **No Working Domains** | fastly_healthcheck.py | `No working domains found` | ✅ NO_DOMAINS |
| **Healthcheck Test Fail** | migration_bypass_nlb.py | `ERROR: Healthcheck test failed:` | ❌ **MISSING** |
| **DNS Zone Not Found** | migration_1/2 | `ERROR: Zone magento.cloud. not found` | ❌ **MISSING** |
| **DNS Resolution Fail** | migration_1 | `ERROR: Failed to resolve hostname` | ❌ **MISSING** |
| **B Record Missing** | migration_2 | `ERROR: Cannot bypass NLB: b record doesn't exist` | ❌ **MISSING** |
| **NLB Not Found** | migration_2 | `ERROR: Cannot use NLB: NLB not found` | ❌ **MISSING** |
| **Route53 API Error** | migration_1/2 | `ERROR: Failed to update DNS` | ❌ **MISSING** |
| **Fastly API Error** | fastly_healthcheck.py | `Error creating healthcheck:` | ❌ **MISSING** |

## Critical Validation Points

### Pre-Migration Checks (All must pass)
1. ✅ HIERA_DIR exists
2. ✅ Not a DG3 cluster  
3. ✅ AWS provider
4. ✅ Fastly service exists
5. ✅ Fastly backend matches cluster
6. ✅ At least one domain works with ALL backend IPs
7. ✅ Route53 zone accessible
8. ✅ Backend IPs resolvable

### During Migration (Atomic operations)
1. **DNS Step 1**: Create B records (forward only)
2. **DNS Step 2**: Update C record  
3. **Fastly Step 3**: Add/Remove healthcheck

### Rollback Differences
- ❌ Skips: Backend validation, healthcheck test, B record creation
- ✅ Requires: NLB discovery, region detection
- ⚠️  Limitation: B records are orphaned (not cleaned up)

## State Consistency

### Success State (Forward)
- `c.cluster.dev` → `b.cluster.dev.ent.magento.cloud` 
- `b.cluster.dev.ent.magento.cloud` → Backend IPs (multivalue)
- Fastly backend uses `psh-origin-hc` healthcheck
- Traffic flows: Client → Fastly → Backend IPs (no NLB)

### Success State (Rollback)
- `c.cluster.dev` → `cluster-dev-nlb.elb.region.amazonaws.com`
- Fastly backend has no healthcheck
- Traffic flows: Client → Fastly → NLB → Backend IPs
- Orphaned: `b.cluster.dev` records remain

### Failure States
Any exit point leaves the system in previous state (no partial changes within each script, but cross-script failures can leave inconsistent state).
