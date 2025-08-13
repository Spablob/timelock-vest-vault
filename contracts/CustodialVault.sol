// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    struct PriceFeed {
        bytes32 id;
        Price price;
        Price emaPrice;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
    function getPrice(bytes32 id) external view returns (Price memory price);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
    
    // Functions for parsing price data without updating on-chain state
    function parsePriceFeedUpdates(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PriceFeed[] memory priceFeeds);
}

/// @title CustodialVault
/// @notice A single-use custodial vault for one borrower and one lender
///         Borrower must call depositCollateral() to transfer IP tokens to the vault
///         Borrower must call ackLoanReceived() within 3 days to begin the 8-month lock period
///         Within 3 days after deposit: borrower cannot withdraw tokens
///         After 3 days if ackLoanReceived() not called: borrower can withdraw tokens
///         Once ackLoanReceived() is called: borrower cannot withdraw tokens anymore
///         
///         Lender withdrawal conditions:
///         1. If not started: lender cannot withdraw
///         2. If started and before lock end: lender can withdraw if liquidation requested 
///            (TWAP <= liquidation price) and 24-hour liquidation window has passed
///         3. If started and after lock end: lender can withdraw without any restrictions
///         
///         Emergency withdrawal: Borrower can propose emergency withdrawal to any address,
///         which requires lender approval before execution
/// @dev Uses Pyth Oracle for price feeds and implements 24-hour TWAP for oracle manipulation protection
contract CustodialVault is ReentrancyGuardTransient {
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant TWAP_WINDOW = 24 hours; // 24 hour TWAP window
    uint256 public constant MAX_PRICE_AGE = 5 minutes; // Maximum acceptable price age
    uint256 public constant PRICE_FRESHNESS_WINDOW = 1 hours; // Price history must be updated within this window
    uint256 public constant LIQUIDATION_TIME_WINDOW = 24 hours; // 24 hour liquidation waiting period
    uint256 public constant MAX_CONFIDENCE_BPS = 300; // 3% maximum confidence interval in basis points

    // Pyth Oracle contract on Story chain
    // Mainnet: 0xD458261E832415CFd3BAE5E416FdF3230ce6F134
    // Testnet (Aeneid): 0x36825bf3Fbdf5a29E2d5148bfe7Dcf7B5639e320
    IPyth public constant PYTH_ORACLE = IPyth(0x36825bf3Fbdf5a29E2d5148bfe7Dcf7B5639e320);

    // IP token price feed ID on Pyth
    bytes32 public constant IP_PRICE_FEED_ID = 0xb620ba83044577029da7e4ded7a2abccf8e6afc2a0d4d26d89ccdd39ec109025;

    // Vault configuration
    address public immutable borrower;
    address public immutable lender;
    uint256 public liquidationPrice; // Can be updated with lender approval
    uint256 public immutable totalTokenAmount;
    uint256 public lockEndTime;

    // Vault state
    bool public withdrawn;
    bool public started;
    uint256 public depositTime; // Timestamp when borrower deposits tokens
    
    // Liquidation price update state
    uint256 public proposedLiquidationPrice;
    bool public liquidationPriceProposalActive;
    
    // Liquidation request state
    uint256 public liquidationRequestTime; // Timestamp when lender requested liquidation
    bool public liquidationRequestActive;
    
    // Emergency withdrawal state
    address public proposedEmergencyRecipient;
    bool public emergencyWithdrawalProposed;
    bool public emergencyWithdrawalApproved;

    struct PricePoint {
        uint192 price;     // Enough for prices up to 6.2e57 with 18 decimals
        uint64 timestamp;  // Unix timestamp, valid until year 584554051223
    }

    // Ring buffer for price history
    uint256 private constant MAX_PRICE_POINTS = 1440; // 24 hours of data with 1-minute intervals
    PricePoint[MAX_PRICE_POINTS] public priceHistory;
    uint256 public priceHistoryLength;
    uint256 public priceHistoryIndex; // Current write position in ring buffer
    uint256 public lastPriceUpdate;

    // Events
    event TokensWithdrawnByBorrower(address indexed borrower, address indexed recipient, uint256 amount);
    event TokensWithdrawnByLender(address indexed lender, uint256 amount, uint256 currentPrice);
    event PriceUpdated(uint256 price, uint256 timestamp);
    event VaultStarted(uint256 lockEndTime);
    event TokensDeposited(address indexed depositor, uint256 amount);
    event LiquidationPriceProposed(uint256 oldPrice, uint256 newPrice);
    event LiquidationPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event LiquidationPriceProposalRejected(uint256 proposedPrice);
    event LiquidationRequested(uint256 timestamp, uint256 twapPrice);
    event LiquidationCancelled(uint256 reason); // 0: manual cancel, 1: price update
    event EmergencyWithdrawalProposed(address indexed proposer, address indexed recipient);
    event EmergencyWithdrawalApproved(address indexed approver);
    event EmergencyWithdrawalExecuted(address indexed recipient, uint256 amount);
    event EmergencyWithdrawalCancelled();

    // Custom errors
    error InvalidAddress();
    error InvalidAmount();
    error InvalidTime();
    error NotAuthorized();
    error LockPeriodNotExpired();
    error LockPeriodExpired();
    error AlreadyWithdrawn();
    error PriceDropThresholdNotMet();
    error StalePrice();
    error InsufficientPriceHistory();
    error InvalidPriceHistory();
    error AlreadyStarted();
    error NotStarted();
    error AlreadyDeposited();
    error NotDeposited();
    error WithdrawalNotAllowed();
    error NoActiveProposal();
    error ProposalAlreadyActive();
    error NoActiveLiquidationRequest();
    error LiquidationRequestAlreadyActive();
    error LiquidationTimeWindowNotPassed();
    error EmergencyWithdrawalNotApproved();
    error NoEmergencyWithdrawalProposed();
    error ExcessiveConfidenceInterval();
    error EmptyPriceUpdateData();
    error TooManyPriceUpdates();
    error TimestampOutOfRange();

    constructor(
        address _borrower,
        address _lender,
        uint256 _liquidationPrice,
        uint256 _totalTokenAmount
    ) {
        if (_borrower == address(0) || _lender == address(0)) revert InvalidAddress();
        if (_liquidationPrice == 0 || _totalTokenAmount == 0) revert InvalidAmount();

        borrower = _borrower;
        lender = _lender;
        liquidationPrice = _liquidationPrice;
        totalTokenAmount = _totalTokenAmount;
    }

    receive() external payable {
        // Accept funds without restriction for backwards compatibility
        // The depositCollateral() function is the preferred method for borrower deposits
    }

    /// @notice Acknowledges loan received and starts the vault lock period (can only be called once by borrower)
    /// @dev Sets the lock end time to current time + 8 months
    function ackLoanReceived() external {
        if (msg.sender != borrower) revert NotAuthorized();
        if (started) revert AlreadyStarted();
        if (depositTime == 0) revert NotDeposited();
        
        started = true;
        lockEndTime = block.timestamp + 8 * 30 days; // Approximately 8 months
        
        emit VaultStarted(lockEndTime);
    }

    /// @notice Allows borrower to deposit IP tokens as collateral to the vault
    /// @dev Can only be called once, starts the 3-day waiting period before withdrawal is allowed
    function depositCollateral() external payable {
        if (msg.sender != borrower) revert NotAuthorized();
        if (depositTime != 0) revert AlreadyDeposited();
        if (msg.value == 0) revert InvalidAmount();
        
        depositTime = block.timestamp;
        
        emit TokensDeposited(msg.sender, msg.value);
    }

    /// @notice Allows borrower to withdraw tokens under specific conditions
    /// @dev Within 3 days of deposit: borrower cannot withdraw
    /// @dev After 3 days of deposit: can withdraw only if ackLoanReceived() was never called
    /// @dev Once ackLoanReceived() is called: borrower cannot withdraw at all
    /// @param recipient The address to receive the withdrawn tokens
    function withdrawByBorrower(address recipient) external nonReentrant {
        if (msg.sender != borrower) revert NotAuthorized();
        if (withdrawn) revert AlreadyWithdrawn();
        if (recipient == address(0)) revert InvalidAddress();
        if (depositTime == 0) revert NotDeposited();

        // If ackLoanReceived() has been called, borrower cannot withdraw
        if (started) {
            revert WithdrawalNotAllowed();
        }

        // Within 3 days: borrower cannot withdraw
        if (block.timestamp <= depositTime + 3 days) {
            revert WithdrawalNotAllowed();
        }

        // After 3 days: can withdraw if ackLoanReceived() was never called

        withdrawn = true;
        uint256 amount = address(this).balance;
        emit TokensWithdrawnByBorrower(borrower, recipient, amount);
        Address.sendValue(payable(recipient), amount);
    }


    /// @notice Allows lender to request liquidation when TWAP is below liquidation price
    /// @dev Starts the 24-hour liquidation time window
    function requestLiquidation() external {
        if (msg.sender != lender) revert NotAuthorized();
        if (withdrawn) revert AlreadyWithdrawn();
        if (liquidationRequestActive) revert LiquidationRequestAlreadyActive();
        
        // Vault must be started to request liquidation
        if (!started) revert NotStarted();
        
        // After lock end, lender can withdraw directly without liquidation request
        if (block.timestamp >= lockEndTime) {
            revert WithdrawalNotAllowed(); // Use withdrawByLender instead
        }
        
        // Ensure price history is fresh
        if (block.timestamp - lastPriceUpdate > PRICE_FRESHNESS_WINDOW) revert StalePrice();
        
        // Get TWAP price
        uint256 twapPrice = _getTWAPPrice();
        
        // Check if we have sufficient price history
        if (priceHistoryLength < MAX_PRICE_POINTS) {
            revert InsufficientPriceHistory();
        }
        
        // Validate price history integrity
        _validatePriceHistory();
        
        // Check if TWAP is at or below liquidation price
        if (twapPrice > liquidationPrice) revert PriceDropThresholdNotMet();
        
        // Set liquidation request
        liquidationRequestActive = true;
        liquidationRequestTime = block.timestamp;
        
        emit LiquidationRequested(block.timestamp, twapPrice);
    }
    
    /// @notice Allows lender to cancel an active liquidation request
    function cancelLiquidationRequest() external {
        if (msg.sender != lender) revert NotAuthorized();
        if (!liquidationRequestActive) revert NoActiveLiquidationRequest();
        
        liquidationRequestActive = false;
        liquidationRequestTime = 0;
        
        emit LiquidationCancelled(0); // 0: manual cancel
    }
    
    /// @notice Allows lender to withdraw all tokens
    /// @dev If not started: cannot withdraw
    /// @dev If started and before lock end: requires active liquidation request and 24-hour wait
    /// @dev If started and after lock end: no restrictions, can withdraw anytime
    function withdrawByLender() external nonReentrant {
        if (msg.sender != lender) revert NotAuthorized();
        if (withdrawn) revert AlreadyWithdrawn();
        
        // Vault must be started for lender to withdraw
        if (!started) revert NotStarted();
        
        uint256 currentPrice = 0;
        
        // Different rules based on whether lock period has ended
        if (block.timestamp < lockEndTime) {
            // Before lock end: require liquidation request and wait period
            if (!liquidationRequestActive) revert NoActiveLiquidationRequest();
            
            // Check if 24-hour liquidation time window has passed
            if (block.timestamp < liquidationRequestTime + LIQUIDATION_TIME_WINDOW) {
                revert LiquidationTimeWindowNotPassed();
            }
            
            // Get current price for event (may be stale after 24h wait, but that's OK)
            try this.getCurrentTWAP() returns (uint256 twap) {
                currentPrice = twap;
            } catch {
                // Price may be stale after waiting, use 0 for event
                currentPrice = 0;
            }
        }
        // After lock end: no restrictions, lender can withdraw freely
        
        withdrawn = true;
        liquidationRequestActive = false;
        liquidationRequestTime = 0;
        uint256 amount = address(this).balance;
        
        emit TokensWithdrawnByLender(lender, amount, currentPrice);
        
        Address.sendValue(payable(lender), amount);
    }

    /// @notice Update price if enough time has passed
    function updatePrice() external {
        _tryUpdatePrice();
    }


    /// @notice Update price history with historical price data
    /// @dev Uses Pyth parsePriceFeedUpdates to fill price history with up to 24 hours of historical data
    /// @param pythUpdateData Array of price update data containing historical prices
    /// @param timestamps Array of timestamps for which to retrieve prices (must be in ascending order)
    function updateHistoricalPrices(
        bytes[] calldata pythUpdateData,
        uint64[] calldata timestamps
    ) external payable {
        if (pythUpdateData.length == 0 || timestamps.length == 0) revert EmptyPriceUpdateData();
        if (timestamps.length > MAX_PRICE_POINTS) revert TooManyPriceUpdates();
        
        // Validate timestamps
        _validateTimestamps(timestamps);
        
        // Calculate fee and validate payment
        uint256 totalFee = PYTH_ORACLE.getUpdateFee(pythUpdateData) * timestamps.length;
        if (msg.value < totalFee) revert InvalidAmount();
        
        // Process updates
        _processHistoricalUpdates(pythUpdateData, timestamps);
        
        // Update last price update time
        if (timestamps.length > 0) {
            lastPriceUpdate = timestamps[timestamps.length - 1];
        }
        
        // Refund excess
        if (msg.value > totalFee) {
            Address.sendValue(payable(msg.sender), msg.value - totalFee);
        }
    }
    
    /// @notice Validate timestamps array
    function _validateTimestamps(uint64[] calldata timestamps) internal view {
        uint256 currentTime = block.timestamp;
        uint256 cutoffTime = currentTime > TWAP_WINDOW ? currentTime - TWAP_WINDOW : 0;
        uint64 previousTimestamp = 0;
        
        for (uint256 i = 0; i < timestamps.length; i++) {
            if (timestamps[i] < cutoffTime || timestamps[i] > currentTime) revert TimestampOutOfRange();
            if (timestamps[i] <= previousTimestamp) revert InvalidPriceHistory();
            previousTimestamp = timestamps[i];
        }
    }
    
    /// @notice Process historical price updates
    function _processHistoricalUpdates(
        bytes[] calldata pythUpdateData,
        uint64[] calldata timestamps
    ) internal {
        bytes32[] memory priceIds = new bytes32[](1);
        priceIds[0] = IP_PRICE_FEED_ID;
        uint256 singleFee = PYTH_ORACLE.getUpdateFee(pythUpdateData);
        
        for (uint256 i = 0; i < timestamps.length; i++) {
            _updateSingleHistoricalPrice(pythUpdateData, priceIds, timestamps[i], singleFee);
        }
    }
    
    /// @notice Update a single historical price
    function _updateSingleHistoricalPrice(
        bytes[] calldata pythUpdateData,
        bytes32[] memory priceIds,
        uint64 timestamp,
        uint256 fee
    ) internal {
        // Calculate time bounds with overflow protection
        uint64 minTime = timestamp > 60 ? timestamp - 60 : 0;
        uint64 maxTime = timestamp < type(uint64).max - 60 ? timestamp + 60 : type(uint64).max;
        
        IPyth.PriceFeed[] memory priceFeeds = PYTH_ORACLE.parsePriceFeedUpdates{value: fee}(
            pythUpdateData,
            priceIds,
            minTime,
            maxTime
        );
        
        if (priceFeeds.length > 0) {
            IPyth.Price memory priceData = priceFeeds[0].price;
            
            // Validate confidence interval
            if (priceData.price > 0) {
                uint256 priceAbs = uint256(uint64(priceData.price));
                uint256 confidence = uint256(priceData.conf);
                
                // Check if confidence is within acceptable range (e.g., 3% of price)
                if (confidence * BASIS_POINTS > priceAbs * MAX_CONFIDENCE_BPS) {
                    revert ExcessiveConfidenceInterval();
                }
            }
            
            uint256 price = _convertPythPrice(priceData);
            
            priceHistory[priceHistoryIndex] = PricePoint({
                price: uint192(price),
                timestamp: timestamp
            });
            priceHistoryIndex = (priceHistoryIndex + 1) % MAX_PRICE_POINTS;
            
            if (priceHistoryLength < MAX_PRICE_POINTS) {
                priceHistoryLength++;
            }
            
            emit PriceUpdated(price, timestamp);
        }
    }

    /// @notice Try to update price if conditions are met
    function _tryUpdatePrice() internal {
        IPyth.Price memory pythPrice = PYTH_ORACLE.getPriceUnsafe(IP_PRICE_FEED_ID);
        
        // Skip if price is stale
        if (pythPrice.publishTime > 0 && block.timestamp > pythPrice.publishTime 
            && block.timestamp - pythPrice.publishTime > MAX_PRICE_AGE) {
            return;
        }

        // Validate confidence interval
        if (pythPrice.price > 0) {
            uint256 priceAbs = uint256(uint64(pythPrice.price));
            uint256 confidence = uint256(pythPrice.conf);
            
            // Skip if confidence is too high (more than 3% of price)
            if (confidence * BASIS_POINTS > priceAbs * MAX_CONFIDENCE_BPS) {
                return;
            }
        }

        // Update price history for TWAP
        if (block.timestamp >= lastPriceUpdate + 1 minutes) {
            uint256 price = _convertPythPrice(pythPrice);
            
            // Write to ring buffer (safe to cast as we control the price conversion)
            priceHistory[priceHistoryIndex] = PricePoint({
                price: uint192(price), 
                timestamp: uint64(block.timestamp)
            });
            priceHistoryIndex = (priceHistoryIndex + 1) % MAX_PRICE_POINTS;
            
            // Increment length up to MAX_PRICE_POINTS
            if (priceHistoryLength < MAX_PRICE_POINTS) {
                priceHistoryLength++;
            }
            
            lastPriceUpdate = block.timestamp;
            emit PriceUpdated(price, block.timestamp);
        }
    }

    /// @notice Calculates Time-Weighted Average Price over the TWAP window
    function _getTWAPPrice() internal view returns (uint256) {
        // Get current price
        IPyth.Price memory currentPythPrice = PYTH_ORACLE.getPriceUnsafe(IP_PRICE_FEED_ID);
        if (
            currentPythPrice.publishTime > 0 && block.timestamp > currentPythPrice.publishTime
                && block.timestamp - currentPythPrice.publishTime > MAX_PRICE_AGE
        ) revert StalePrice();
        uint256 currentPrice = _convertPythPrice(currentPythPrice);

        if (priceHistoryLength == 0) {
            return currentPrice;
        }

        uint256 cutoffTime = block.timestamp > TWAP_WINDOW ? block.timestamp - TWAP_WINDOW : 0;
        uint256 weightedSum = 0;
        uint256 totalWeight = 0;

        // Calculate TWAP including current price
        uint256 lastTimestamp = block.timestamp;
        uint256 lastPrice = currentPrice;

        // Get the most recent index (one before current write position)
        uint256 readIndex = priceHistoryIndex > 0 ? priceHistoryIndex - 1 : MAX_PRICE_POINTS - 1;
        
        // Iterate through ring buffer in reverse order
        for (uint256 i = 0; i < priceHistoryLength; i++) {
            PricePoint memory point = priceHistory[readIndex];
            
            // Skip uninitialized entries
            if (point.timestamp == 0) {
                break;
            }

            if (point.timestamp < cutoffTime) {
                // Partial weight for the edge case
                if (lastTimestamp > cutoffTime) {
                    uint256 partialTimeWeight = lastTimestamp - cutoffTime;
                    weightedSum += lastPrice * partialTimeWeight;
                    totalWeight += partialTimeWeight;
                }
                break;
            }

            uint256 timeWeight = lastTimestamp - uint256(point.timestamp);
            weightedSum += lastPrice * timeWeight;
            totalWeight += timeWeight;

            lastTimestamp = uint256(point.timestamp);
            lastPrice = uint256(point.price);
            
            // Move to previous entry in ring buffer
            readIndex = readIndex > 0 ? readIndex - 1 : MAX_PRICE_POINTS - 1;
        }

        // If we don't have enough history, use current price
        if (totalWeight == 0) {
            return currentPrice;
        }

        return weightedSum / totalWeight;
    }

    /// @notice Validates price history integrity
    /// @dev Ensures all entries are within 24 hours and chronologically ordered
    function _validatePriceHistory() internal view {
        uint256 cutoffTime = block.timestamp > TWAP_WINDOW ? block.timestamp - TWAP_WINDOW : 0;
        uint256 previousTimestamp = 0;
        uint256 oldestValidTimestamp = block.timestamp;
        
        // Get the most recent index (one before current write position)
        uint256 readIndex = priceHistoryIndex > 0 ? priceHistoryIndex - 1 : MAX_PRICE_POINTS - 1;
        
        // Check all entries in the ring buffer
        for (uint256 i = 0; i < MAX_PRICE_POINTS && i < priceHistoryLength; i++) {
            PricePoint memory point = priceHistory[readIndex];
            
            // Skip if we reach uninitialized entries
            if (point.timestamp == 0) {
                break;
            }
            
            // Stop if entry is older than 24 hours
            if (point.timestamp < cutoffTime) {
                break;
            }
            
            // First valid entry
            if (previousTimestamp == 0) {
                previousTimestamp = point.timestamp;
            } else {
                // Check chronological order (older entries should have lower timestamps)
                if (point.timestamp >= previousTimestamp) {
                    revert InvalidPriceHistory();
                }
                previousTimestamp = point.timestamp;
            }
            
            // Track oldest valid timestamp
            oldestValidTimestamp = point.timestamp;
            
            // Move to previous entry in ring buffer
            readIndex = readIndex > 0 ? readIndex - 1 : MAX_PRICE_POINTS - 1;
        }
        
        // Ensure we have close to 24 hours of data (allow 23.5 hours minimum)
        uint256 timeSpan = block.timestamp - oldestValidTimestamp;
        if (timeSpan < 23.5 hours) {
            revert InvalidPriceHistory();
        }
    }

    /// @notice Converts Pyth price format to 18 decimals
    function _convertPythPrice(IPyth.Price memory pythPrice) internal pure returns (uint256) {
        // Ensure price is positive
        if (pythPrice.price <= 0) revert InvalidAmount();
        
        uint256 price = uint256(uint64(pythPrice.price));

        if (pythPrice.expo >= 0) {
            return price * (10 ** uint32(pythPrice.expo)) * (10 ** 18);
        } else {
            uint32 negExpo = uint32(-pythPrice.expo);
            if (negExpo > 18) {
                return price / (10 ** (negExpo - 18));
            } else {
                return price * (10 ** (18 - negExpo));
            }
        }
    }

    /// @notice Get vault details
    function getVaultDetails()
        external
        view
        returns (
            uint256 liqPrice,
            uint256 tokenAmount,
            uint256 lockEnd,
            uint256 depositTimestamp,
            bool isStarted,
            bool isWithdrawn,
            uint256 currentBalance
        )
    {
        return (liquidationPrice, totalTokenAmount, lockEndTime, depositTime, started, withdrawn, address(this).balance);
    }

    /// @notice Get current TWAP price
    function getCurrentTWAP() external view returns (uint256) {
        return _getTWAPPrice();
    }

    /// @notice Get latest price from oracle
    function getCurrentPrice() external view returns (uint256) {
        IPyth.Price memory pythPrice = PYTH_ORACLE.getPriceUnsafe(IP_PRICE_FEED_ID);
        return _convertPythPrice(pythPrice);
    }

    /// @notice Get price history length
    function getPriceHistoryLength() external view returns (uint256) {
        return priceHistoryLength;
    }

    /// @notice Get current timestamp
    function getCurrentTime() external view returns (uint256) {
        return block.timestamp;
    }

    /// @notice Propose a new liquidation price (borrower only)
    /// @param newLiquidationPrice The proposed new liquidation price
    function proposeLiquidationPrice(uint256 newLiquidationPrice) external {
        if (msg.sender != borrower) revert NotAuthorized();
        if (newLiquidationPrice == 0) revert InvalidAmount();
        if (liquidationPriceProposalActive) revert ProposalAlreadyActive();
        
        proposedLiquidationPrice = newLiquidationPrice;
        liquidationPriceProposalActive = true;
        
        emit LiquidationPriceProposed(liquidationPrice, newLiquidationPrice);
    }

    /// @notice Approve the proposed liquidation price (lender only)
    function approveLiquidationPrice() external {
        if (msg.sender != lender) revert NotAuthorized();
        if (!liquidationPriceProposalActive) revert NoActiveProposal();
        
        uint256 oldPrice = liquidationPrice;
        liquidationPrice = proposedLiquidationPrice;
        
        // Reset proposal state
        proposedLiquidationPrice = 0;
        liquidationPriceProposalActive = false;
        
        // Cancel any active liquidation request if price update makes it invalid
        if (liquidationRequestActive) {
            liquidationRequestActive = false;
            liquidationRequestTime = 0;
            emit LiquidationCancelled(1); // 1: price update
        }
        
        emit LiquidationPriceUpdated(oldPrice, liquidationPrice);
    }

    /// @notice Reject the proposed liquidation price (lender only)
    function rejectLiquidationPrice() external {
        if (msg.sender != lender) revert NotAuthorized();
        if (!liquidationPriceProposalActive) revert NoActiveProposal();
        
        uint256 rejectedPrice = proposedLiquidationPrice;
        
        // Reset proposal state
        proposedLiquidationPrice = 0;
        liquidationPriceProposalActive = false;
        
        emit LiquidationPriceProposalRejected(rejectedPrice);
    }

    /// @notice Propose an emergency withdrawal (borrower only)
    /// @param recipient The address to receive the emergency withdrawal
    function proposeEmergencyWithdrawal(address recipient) external {
        if (msg.sender != borrower) revert NotAuthorized();
        if (recipient == address(0)) revert InvalidAddress();
        if (withdrawn) revert AlreadyWithdrawn();
        
        proposedEmergencyRecipient = recipient;
        emergencyWithdrawalProposed = true;
        emergencyWithdrawalApproved = false;
        
        emit EmergencyWithdrawalProposed(msg.sender, recipient);
    }

    /// @notice Approve the emergency withdrawal (lender only)
    function approveEmergencyWithdrawal() external {
        if (msg.sender != lender) revert NotAuthorized();
        if (!emergencyWithdrawalProposed) revert NoEmergencyWithdrawalProposed();
        
        emergencyWithdrawalApproved = true;
        
        emit EmergencyWithdrawalApproved(msg.sender);
    }

    /// @notice Execute the approved emergency withdrawal (borrower only)
    function executeEmergencyWithdrawal() external nonReentrant {
        if (msg.sender != borrower) revert NotAuthorized();
        if (!emergencyWithdrawalProposed) revert NoEmergencyWithdrawalProposed();
        if (!emergencyWithdrawalApproved) revert EmergencyWithdrawalNotApproved();
        if (withdrawn) revert AlreadyWithdrawn();
        
        withdrawn = true;
        address recipient = proposedEmergencyRecipient;
        uint256 amount = address(this).balance;
        
        // Reset emergency withdrawal state
        proposedEmergencyRecipient = address(0);
        emergencyWithdrawalProposed = false;
        emergencyWithdrawalApproved = false;
        
        // Cancel any active liquidation request
        if (liquidationRequestActive) {
            liquidationRequestActive = false;
            liquidationRequestTime = 0;
        }
        
        emit EmergencyWithdrawalExecuted(recipient, amount);
        
        Address.sendValue(payable(recipient), amount);
    }

    /// @notice Cancel the emergency withdrawal proposal (borrower or lender)
    function cancelEmergencyWithdrawal() external {
        if (msg.sender != borrower && msg.sender != lender) revert NotAuthorized();
        if (!emergencyWithdrawalProposed) revert NoEmergencyWithdrawalProposed();
        
        proposedEmergencyRecipient = address(0);
        emergencyWithdrawalProposed = false;
        emergencyWithdrawalApproved = false;
        
        emit EmergencyWithdrawalCancelled();
    }

}