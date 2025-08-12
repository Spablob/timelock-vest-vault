# CustodialVault Code Review Guide

## Contract Overview

**File**: `contracts/CustodialVault.sol`  
**Purpose**: Time-locked token vault with price-based protection for lenders  
**Key Innovation**: Combines vesting with downside protection using TWAP pricing

## Critical Functions for Lenders

### 1. `withdrawByLender()` - Your Protection Mechanism

```solidity
function withdrawByLender() external nonReentrant
```

**What it does:**
- Allows you to withdraw all tokens if price drops ≥50%
- Only callable by the designated lender address
- Protected against reentrancy attacks

**Key Checks:**
1. `msg.sender == lender` - Only you can call this
2. `block.timestamp < lockEndTime` - Can't withdraw after lock period
3. `!withdrawn` - Prevents double withdrawal
4. `priceHistoryLength >= 1440` - Requires 24 hours of price data
5. `block.timestamp - lastPriceUpdate <= 2 minutes` - Price must be fresh
6. `priceDropBps >= 5000` - Price must have dropped ≥50%

**Review Points:**
- ✅ All conditions are properly enforced with custom errors
- ✅ Uses TWAP price, not spot price (manipulation resistant)
- ✅ Validates price history integrity (chronological order, 23.5+ hours of data)
- ✅ Transfers entire balance, no partial withdrawals
- ✅ Emits event for transparency

### 2. `_getTWAPPrice()` - Price Calculation Logic

```solidity
function _getTWAPPrice() internal view returns (uint256)
```

**What it does:**
- Calculates 24-hour time-weighted average price
- Uses ring buffer for efficient storage (1440 price points)
- Weights prices by time duration

**Key Features:**
- Iterates through price history in reverse chronological order
- Handles edge cases (partial windows, initialization)
- Returns current price if insufficient history

**Review Points:**
- ✅ Correctly implements TWAP algorithm
- ✅ Ring buffer prevents unbounded array growth
- ✅ Handles all edge cases properly

### 3. `_validatePriceHistory()` - Price History Validation

```solidity
function _validatePriceHistory() internal view
```

**What it does:**
- Validates that price history entries are in chronological order
- Ensures we have at least 23.5 hours of price data
- Prevents manipulation through invalid price sequences

**Key Features:**
- Checks all entries within the 24-hour window
- Verifies timestamps decrease monotonically (going backwards in time)
- Requires minimum time span to prevent insufficient data attacks

**Review Points:**
- ✅ Prevents out-of-order price manipulation
- ✅ Ensures sufficient historical data for accurate TWAP
- ✅ Only validates data within the TWAP window

### 4. Price Update Mechanism

```solidity
function refreshFeedsAndUpdatePrice(bytes[] calldata pythUpdateData) external payable
```

**What it does:**
- Updates Pyth oracle with fresh price data
- Records new price in history if ≥1 minute has passed
- Refunds excess oracle fees

**Security:**
- Anyone can call (keeps prices fresh)
- Validates oracle fees are paid
- Only updates once per minute (gas efficient)

## Storage Layout & Gas Optimization

### Packed Storage Structure

```solidity
struct PricePoint {
    uint192 price;     // 24 bytes - supports prices up to 6.2e57
    uint64 timestamp;  // 8 bytes - valid until year 584,554,051,223
}
```

**Optimization**: Packs price and timestamp into single 32-byte slot, reducing storage costs by 50%

### Ring Buffer Implementation

```solidity
PricePoint[1440] public priceHistory;  // Fixed size array
uint256 public priceHistoryIndex;      // Current write position
```

**Benefits**:
- O(1) insertion time
- No array resizing or shifting
- Predictable gas costs

## Security Analysis

### 1. Access Control
- ✅ **Lender-only functions**: `withdrawByLender()`
- ✅ **Foundation-only functions**: `withdrawByFoundation()`
- ✅ **Public functions**: Price updates (intentional)

### 2. Reentrancy Protection
```solidity
contract CustodialVault is ReentrancyGuardTransient
```
- Uses OpenZeppelin's transient storage guard (EIP-1153)
- More gas efficient than traditional reentrancy guards

### 3. Oracle Security
- ✅ Uses Pyth Network (cryptographically signed prices)
- ✅ Validates price age (max 5 minutes old)
- ✅ Checks for positive prices only
- ✅ TWAP prevents flash loan manipulation

### 4. Integer Overflow Protection
- Solidity 0.8.26 has built-in overflow protection
- Additional validation in `_convertPythPrice()`

## Edge Cases Handled

### 1. Insufficient Price History
```solidity
if (priceHistoryLength < MAX_PRICE_POINTS) {
    revert InsufficientPriceHistory();
}
```
- Prevents withdrawals until 24 hours of data exists

### 2. Stale Prices
```solidity
if (block.timestamp - lastPriceUpdate > PRICE_FRESHNESS_WINDOW) {
    revert StalePrice();
}
```
- Ensures decisions based on recent data

### 3. Price at Exactly 50% Drop
```solidity
if (priceDropBps >= PRICE_DROP_THRESHOLD)  // >= not >
```
- Inclusive threshold favors lender protection

### 4. Negative Oracle Prices
```solidity
if (pythPrice.price <= 0) revert InvalidAmount();
```
- Prevents invalid price data from being used

## Constants Verification

```solidity
PRICE_DROP_THRESHOLD = 5000     // 50% in basis points ✓
BASIS_POINTS = 10000            // Standard denomination ✓
TWAP_WINDOW = 24 hours          // 86,400 seconds ✓
MAX_PRICE_AGE = 5 minutes       // 300 seconds ✓
PRICE_FRESHNESS_WINDOW = 2 min  // 120 seconds ✓
MAX_PRICE_POINTS = 1440         // 24 hours * 60 minutes ✓
```

## Potential Concerns & Mitigations

### 1. Oracle Dependency
**Risk**: Pyth oracle failure could prevent withdrawals  
**Mitigation**: 5-minute grace period for oracle data age

### 2. Gas Costs
**Risk**: TWAP calculation iterates through up to 1440 points  
**Mitigation**: Only during withdrawal (infrequent operation)

### 3. Front-Running
**Risk**: Someone could update prices before your withdrawal  
**Mitigation**: TWAP makes manipulation extremely expensive

### 4. Approval After Lock
**Risk**: Lender might not approve foundation withdrawal  
**Mitigation**: This is intentional - gives lender final control

## Deployment Verification Checklist

When reviewing a deployed CustodialVault:

1. **Verify Constructor Parameters**:
   ```solidity
   foundation     // Correct address?
   lender         // Your address?
   initialPrice   // Matches agreement?
   totalTokenAmount // Expected amount?
   lockEndTime    // Correct date?
   ```

2. **Check Pyth Oracle Address**:
   - Testnet: `0x36825bf3Fbdf5a29E2d5148bfe7Dcf7B5639e320`
   - Mainnet: `0xD458261E832415CFd3BAE5E416FdF3230ce6F134`

3. **Verify Price Feed ID**:
   - IP token: `0xb620ba83044577029da7e4ded7a2abccf8e6afc2a0d4d26d89ccdd39ec109025`

4. **Test Price Updates**:
   - Call `updatePrice()` to ensure oracle is working
   - Check `getCurrentPrice()` returns reasonable value

## Code Quality Assessment

### Strengths
- ✅ Well-commented and documented
- ✅ Comprehensive error handling with custom errors
- ✅ Gas-optimized storage patterns
- ✅ Follows security best practices
- ✅ Extensive test coverage (37 tests including edge cases)

### Architecture
- ✅ Single-purpose vault (no feature creep)
- ✅ Immutable configuration (no admin changes)
- ✅ Clear separation of concerns
- ✅ Event emission for all major actions

## Summary

The CustodialVault implementation is robust and secure for lenders:

1. **Protection Works**: 50% drop threshold with TWAP is implemented correctly
2. **No Admin Risk**: No owner functions or upgradability
3. **Oracle Integration**: Properly integrated with Pyth Network
4. **Gas Efficient**: Optimized storage and ring buffer implementation
5. **Battle-Tested Components**: Uses OpenZeppelin for critical features

The contract successfully balances lender protection with foundation needs while preventing common attack vectors through TWAP pricing and proper access controls.