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

    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
    function getPrice(bytes32 id) external view returns (Price memory price);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
}

/// @title CustodialVault
/// @notice A single-use custodial vault for one foundation and one lender
///         Anyone can transfer IP tokens to the vault
///         Foundation can withdraw after lock period with lender approval
///         Lender can withdraw before lock period if price drops by threshold (initially 50%, adjustable)
///         Lender can withdraw after lock period without any restrictions
///         Foundation can propose to increase threshold with lender approval
/// @dev Uses Pyth Oracle for price feeds and implements 24-hour TWAP for oracle manipulation protection
contract CustodialVault is ReentrancyGuardTransient {
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant TWAP_WINDOW = 24 hours; // 24 hour TWAP window
    uint256 public constant MAX_PRICE_AGE = 5 minutes; // Maximum acceptable price age
    uint256 public constant PRICE_FRESHNESS_WINDOW = 2 minutes; // Price history must be updated within this window
    uint256 public constant INITIAL_PRICE_DROP_THRESHOLD = 5000; // Initial 50% in basis points
    uint256 public constant MAX_PRICE_DROP_THRESHOLD = 9000; // Maximum 90% in basis points

    // Pyth Oracle contract on Story chain
    // Mainnet: 0xD458261E832415CFd3BAE5E416FdF3230ce6F134
    // Testnet (Aeneid): 0x36825bf3Fbdf5a29E2d5148bfe7Dcf7B5639e320
    IPyth public constant PYTH_ORACLE = IPyth(0x36825bf3Fbdf5a29E2d5148bfe7Dcf7B5639e320);

    // IP token price feed ID on Pyth
    bytes32 public constant IP_PRICE_FEED_ID = 0xb620ba83044577029da7e4ded7a2abccf8e6afc2a0d4d26d89ccdd39ec109025;

    // Vault configuration
    address public immutable foundation;
    address public immutable lender;
    uint256 public immutable initialPrice;
    uint256 public immutable totalTokenAmount;
    uint256 public immutable lockEndTime;

    // Vault state
    bool public withdrawn;
    bool public lenderApproval;
    
    // Current price drop threshold (can be increased with lender approval)
    uint256 public priceDropThreshold;
    
    // Threshold increase proposal
    uint256 public proposedThreshold;
    bool public thresholdProposalActive;

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
    event TokensWithdrawnByFoundation(address indexed foundation, address indexed recipient, uint256 amount);
    event TokensWithdrawnByLender(address indexed lender, uint256 amount, uint256 currentPrice);
    event LenderApprovalGranted(address indexed lender);
    event PriceUpdated(uint256 price, uint256 timestamp);
    event ThresholdIncreaseProposed(uint256 proposedThreshold, address indexed proposer);
    event ThresholdIncreaseApproved(uint256 newThreshold, address indexed approver);
    event ThresholdIncreaseRejected(address indexed rejector);

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
    error LenderApprovalRequired();
    error InsufficientPriceHistory();
    error InvalidThreshold();
    error ProposalAlreadyActive();
    error NoActiveProposal();

    constructor(
        address _foundation,
        address _lender,
        uint256 _initialPrice,
        uint256 _totalTokenAmount,
        uint256 _lockEndTime
    ) {
        if (_foundation == address(0) || _lender == address(0)) revert InvalidAddress();
        if (_initialPrice == 0 || _totalTokenAmount == 0) revert InvalidAmount();
        if (_lockEndTime <= block.timestamp) revert InvalidTime();

        foundation = _foundation;
        lender = _lender;
        initialPrice = _initialPrice;
        totalTokenAmount = _totalTokenAmount;
        lockEndTime = _lockEndTime;
        priceDropThreshold = INITIAL_PRICE_DROP_THRESHOLD; // Initialize to 50%
    }

    receive() external payable {
        // Accept funds without updating price to save gas
        // Price updates can be triggered via updatePrice() function
    }

    /// @notice Allows foundation to withdraw all tokens after lock period with lender approval
    /// @param recipient The address to receive the withdrawn tokens
    function withdrawByFoundation(address recipient) external nonReentrant {
        if (msg.sender != foundation) revert NotAuthorized();
        if (block.timestamp < lockEndTime) revert LockPeriodNotExpired();
        if (!lenderApproval) revert LenderApprovalRequired();
        if (withdrawn) revert AlreadyWithdrawn();
        if (recipient == address(0)) revert InvalidAddress();

        withdrawn = true;
        uint256 amount = address(this).balance;

        emit TokensWithdrawnByFoundation(foundation, recipient, amount);

        Address.sendValue(payable(recipient), amount);
    }

    /// @notice Allows lender to approve foundation withdrawal
    function approveFoundationWithdrawal() external {
        if (msg.sender != lender) revert NotAuthorized();
        if (block.timestamp < lockEndTime) revert LockPeriodNotExpired();
        
        lenderApproval = true;
        emit LenderApprovalGranted(lender);
    }

    /// @notice Allows lender to withdraw all tokens
    /// @dev Before lock end: requires price drop >= threshold
    /// @dev After lock end: no restrictions, can withdraw anytime
    function withdrawByLender() external nonReentrant {
        if (msg.sender != lender) revert NotAuthorized();
        if (withdrawn) revert AlreadyWithdrawn();
        
        uint256 currentPrice = 0;
        
        // Different rules based on whether lock period has ended
        if (block.timestamp < lockEndTime) {
            // Before lock end: enforce price drop requirements
            
            // Ensure price history is fresh (updated within PRICE_FRESHNESS_WINDOW)
            if (block.timestamp - lastPriceUpdate > PRICE_FRESHNESS_WINDOW) revert StalePrice();

            // Get TWAP price
            currentPrice = _getTWAPPrice();

            // Check if we have sufficient price history (must have full 24 hours of data)
            if (priceHistoryLength < MAX_PRICE_POINTS) {
                revert InsufficientPriceHistory();
            }

            // Check if price has dropped by the threshold amount or more
            if (currentPrice >= initialPrice) revert PriceDropThresholdNotMet();
            uint256 priceDropBps = ((initialPrice - currentPrice) * BASIS_POINTS) / initialPrice;
            if (priceDropBps < priceDropThreshold) revert PriceDropThresholdNotMet();
        }
        // After lock end: no restrictions, lender can withdraw freely

        withdrawn = true;
        uint256 amount = address(this).balance;

        emit TokensWithdrawnByLender(lender, amount, currentPrice);

        Address.sendValue(payable(lender), amount);
    }

    /// @notice Update price if enough time has passed
    function updatePrice() external {
        _tryUpdatePrice();
    }

    /// @notice Refresh Pyth price feeds and update price history
    /// @dev Anyone can call this to ensure price data is fresh
    /// @param pythUpdateData Price update data from Pyth oracle
    function refreshFeedsAndUpdatePrice(bytes[] calldata pythUpdateData) external payable {
        // Update Pyth price feeds if data provided
        if (pythUpdateData.length > 0) {
            uint256 updateFee = PYTH_ORACLE.getUpdateFee(pythUpdateData);
            if (msg.value < updateFee) revert InvalidAmount();
            
            PYTH_ORACLE.updatePriceFeeds{value: updateFee}(pythUpdateData);
            
            // Refund excess payment
            if (msg.value > updateFee) {
                Address.sendValue(payable(msg.sender), msg.value - updateFee);
            }
        }
        
        // Update price history
        _tryUpdatePrice();
    }

    /// @notice Try to update price if conditions are met
    function _tryUpdatePrice() internal {
        IPyth.Price memory pythPrice = PYTH_ORACLE.getPriceUnsafe(IP_PRICE_FEED_ID);
        
        // Skip if price is stale
        if (pythPrice.publishTime > 0 && block.timestamp > pythPrice.publishTime 
            && block.timestamp - pythPrice.publishTime > MAX_PRICE_AGE) {
            return;
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
            uint256 initPrice,
            uint256 tokenAmount,
            uint256 lockEnd,
            bool isWithdrawn,
            bool hasLenderApproval,
            uint256 currentBalance
        )
    {
        return (initialPrice, totalTokenAmount, lockEndTime, withdrawn, lenderApproval, address(this).balance);
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

    /// @notice Allows foundation to propose an increase to the price drop threshold
    /// @dev Can only increase the threshold (make it harder to withdraw), not decrease
    /// @param newThreshold The new threshold in basis points (e.g., 6000 = 60%)
    function proposeThresholdIncrease(uint256 newThreshold) external {
        if (msg.sender != foundation) revert NotAuthorized();
        if (withdrawn) revert AlreadyWithdrawn();
        if (thresholdProposalActive) revert ProposalAlreadyActive();
        
        // Validate new threshold
        if (newThreshold <= priceDropThreshold) revert InvalidThreshold(); // Must be an increase
        if (newThreshold > MAX_PRICE_DROP_THRESHOLD) revert InvalidThreshold(); // Cannot exceed max
        
        proposedThreshold = newThreshold;
        thresholdProposalActive = true;
        
        emit ThresholdIncreaseProposed(newThreshold, msg.sender);
    }

    /// @notice Allows lender to approve the proposed threshold increase
    function approveThresholdIncrease() external {
        if (msg.sender != lender) revert NotAuthorized();
        if (!thresholdProposalActive) revert NoActiveProposal();
        if (withdrawn) revert AlreadyWithdrawn();
        
        uint256 newThreshold = proposedThreshold;
        priceDropThreshold = newThreshold;
        thresholdProposalActive = false;
        proposedThreshold = 0;
        
        emit ThresholdIncreaseApproved(newThreshold, msg.sender);
    }

    /// @notice Allows lender to reject the proposed threshold increase
    function rejectThresholdIncrease() external {
        if (msg.sender != lender) revert NotAuthorized();
        if (!thresholdProposalActive) revert NoActiveProposal();
        
        thresholdProposalActive = false;
        proposedThreshold = 0;
        
        emit ThresholdIncreaseRejected(msg.sender);
    }
}