# CustodialVault Flow Diagram

## Contract Lifecycle

```mermaid
graph TD
    A[Contract Deployment] -->|Initialize with parameters| B[Empty Vault]
    B -->|Anyone transfers IP tokens| C[Funded Vault]
    C -->|Price Updates| D{Monitor Price}
    
    D -->|Price >= 50% of initial| E[Normal Vesting Path]
    D -->|Price < 50% of initial| F[Protection Path]
    
    E -->|Time passes| G{Lock Period End?}
    F -->|Lender acts quickly| H[Lender Withdraws All]
    
    G -->|No| D
    G -->|Yes| I[Foundation Requests Withdrawal]
    I -->|Lender approves| J[Foundation Withdraws]
    I -->|Lender doesn't approve| K[Tokens Locked]
    
    H -->|Complete| L[Vault Empty - End]
    J -->|Complete| L
    
    style A fill:#f9f,stroke:#333,stroke-width:4px
    style H fill:#f96,stroke:#333,stroke-width:4px
    style J fill:#6f9,stroke:#333,stroke-width:4px
    style L fill:#999,stroke:#333,stroke-width:4px
```

## Price Monitoring System

```mermaid
graph LR
    A[Pyth Oracle] -->|Price Feed| B[Update Function]
    B -->|Every Minute| C[Price History Buffer]
    C -->|1440 Points| D[TWAP Calculator]
    D -->|24hr Average| E{Price Check}
    E -->|>= 50% Drop| F[Withdrawal Enabled]
    E -->|< 50% Drop| G[Withdrawal Blocked]
    
    style A fill:#6cf,stroke:#333,stroke-width:2px
    style C fill:#fc6,stroke:#333,stroke-width:2px
    style F fill:#6f6,stroke:#333,stroke-width:2px
    style G fill:#f66,stroke:#333,stroke-width:2px
```

## Withdrawal Decision Tree

```mermaid
graph TD
    A[Withdrawal Attempt] --> B{Who is calling?}
    
    B -->|Lender| C{Before Lock End?}
    B -->|Foundation| D{After Lock End?}
    B -->|Other| E[Reject: Not Authorized]
    
    C -->|Yes| F{Already Withdrawn?}
    C -->|No| E1[Reject: Lock Expired]
    
    D -->|Yes| G{Already Withdrawn?}
    D -->|No| E2[Reject: Lock Not Expired]
    
    F -->|No| H{Price Fresh?}
    F -->|Yes| E3[Reject: Already Withdrawn]
    
    G -->|No| I{Lender Approved?}
    G -->|Yes| E4[Reject: Already Withdrawn]
    
    H -->|Yes < 2min| J{24hr History?}
    H -->|No > 2min| E5[Reject: Stale Price]
    
    J -->|Yes >= 1440| K{TWAP < 50%?}
    J -->|No < 1440| E6[Reject: Insufficient History]
    
    K -->|Yes| L[SUCCESS: Transfer All Tokens]
    K -->|No| E7[Reject: Threshold Not Met]
    
    I -->|Yes| M[SUCCESS: Transfer to Recipient]
    I -->|No| E8[Reject: Approval Required]
    
    style L fill:#6f6,stroke:#333,stroke-width:4px
    style M fill:#6f6,stroke:#333,stroke-width:4px
    style E fill:#f66,stroke:#333,stroke-width:2px
    style E1 fill:#f66,stroke:#333,stroke-width:2px
    style E2 fill:#f66,stroke:#333,stroke-width:2px
    style E3 fill:#f66,stroke:#333,stroke-width:2px
    style E4 fill:#f66,stroke:#333,stroke-width:2px
    style E5 fill:#f66,stroke:#333,stroke-width:2px
    style E6 fill:#f66,stroke:#333,stroke-width:2px
    style E7 fill:#f66,stroke:#333,stroke-width:2px
    style E8 fill:#f66,stroke:#333,stroke-width:2px
```

## Time-Weighted Average Price (TWAP) Calculation

```
Price History (Ring Buffer):
┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
│ T-24│ T-23│ ... │ T-2 │ T-1 │  T  │ T-24│ T-23│  <- Circular buffer
└─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
                              ↑
                        Current Index

TWAP = Σ(Price × Duration) / Total Duration

Example:
- Price at T-24h: \$1.00 for 1 hour
- Price at T-23h: \$0.95 for 1 hour
- ...
- Price at T-1h: \$0.52 for 1 hour
- Price at T: \$0.48 for 1 hour

TWAP = (1.00×1 + 0.95×1 + ... + 0.52×1 + 0.48×1) / 24
```

## Security Model

```mermaid
graph TB
    subgraph "Access Control"
        A1[Lender Functions]
        A2[Foundation Functions]
        A3[Public Functions]
    end
    
    subgraph "Price Security"
        B1[Pyth Oracle Signatures]
        B2[TWAP Anti-Manipulation]
        B3[Freshness Checks]
    end
    
    subgraph "Withdrawal Security"
        C1[Reentrancy Guard]
        C2[Single Withdrawal]
        C3[Time Constraints]
    end
    
    A1 --> D[withdrawByLender]
    A1 --> E[approveFoundationWithdrawal]
    A2 --> F[withdrawByFoundation]
    A3 --> G[updatePrice/refreshFeeds]
    
    B1 --> G
    B2 --> D
    B3 --> D
    
    C1 --> D
    C1 --> F
    C2 --> D
    C2 --> F
    C3 --> D
    C3 --> F
    
    style A1 fill:#f96,stroke:#333,stroke-width:2px
    style A2 fill:#69f,stroke:#333,stroke-width:2px
    style A3 fill:#6f6,stroke:#333,stroke-width:2px
```

## Common Scenarios Timeline

### Scenario 1: Successful Vesting
```
Day 0                Day 120              Day 243
  |----------------------|-------------------|
  ↓                      ↓                   ↓
Deploy              Price stable         Lock ends
\$1.00               \$0.85-\$1.15         Lender approves
                                        Foundation withdraws
```

### Scenario 2: Market Crash Protection
```
Day 0      Day 30        Day 45         Day 60
  |----------|------------|--------------|
  ↓          ↓            ↓              ↓
Deploy    Price=\$0.70  Price=\$0.45   Lender withdraws
\$1.00     (30% drop)   (55% drop)    (TWAP < 50%)
```

### Scenario 3: Flash Crash (No Withdrawal)
```
Day 0      Day 30                  Day 31
  |----------|----------------------|
  ↓          ↓                      ↓
Deploy    Flash to \$0.30         Price=\$0.95
\$1.00     (few minutes)          TWAP still ~\$0.94
          No withdrawal possible
```

## Key Takeaways

1. **Dual Path System**: Either lender gets protection OR foundation gets tokens
2. **Time Windows Matter**: Act before lock period ends if price drops
3. **TWAP Protection**: Prevents manipulation but requires patience
4. **No Partial Solutions**: All-or-nothing withdrawals keep it simple
5. **Transparent Process**: All actions emit events for monitoring