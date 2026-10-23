// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {NoncesKeyedUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesKeyedUpgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {Martingaler} from "./Martingaler.sol";
import {Position, PositionLib} from "./PositionLib.sol";
import {Config, Instrument, InstrumentLib, WAD} from "./InstrumentLib.sol";
import {TraderStats, TraderStatsLib} from "./TraderStatsLib.sol";
import {IPerpetualFutures, OpenRequest, CloseRequest} from "./interfaces/IPerpetualFutures.sol";

struct Settlement {
    uint256 returned;
    uint256 owed;
    uint256 lost;
    uint256 fee;
}

contract PerpetualFutures is
    IPerpetualFutures,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    NoncesKeyedUpgradeable,
    Martingaler
{
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.UintSet;
    using PositionLib for Position;
    using InstrumentLib for Instrument;
    using TraderStatsLib for TraderStats;

    bytes32 public constant OPEN_POSITION_TYPEHASH = keccak256(
        "OpenPosition(address trader,uint32 instrumentId,bool isLong,uint128 collateral,uint32 leverage,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant CLOSE_POSITIONS_TYPEHASH =
        keccak256("ClosePositions(address trader,uint256[] positionIds,uint256 nonce,uint256 deadline)");

    IPyth public pyth;

    uint256 public maxPriceAge;
    mapping(uint32 => Instrument) public instruments;
    uint32 public instrumentCount;
    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId;
    mapping(address => EnumerableSet.UintSet) internal openPositionIdsOf;
    uint256 public totalLockedMargin;
    uint256 public lossFeeRate;
    uint256 public winFeeRate;
    uint256 public liquidationFeeRate;
    uint256 public minCollateral;
    uint256 public minNotional;
    mapping(address => bool) public isExecutor;
    mapping(address => TraderStats) public traderStats;
    TraderStats public totalStats;

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address pyth_, address collateral_) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __EIP712_init("PerpetualFutures", "1");

        pyth = IPyth(pyth_);
        _initCollateral(collateral_);

        maxPriceAge = 60;
        lossFeeRate = 0.02e18;
        winFeeRate = 0.02e18;
        liquidationFeeRate = 0.02e18;
        minCollateral = WAD;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    modifier onlyExecutor() {
        if (!isExecutor[msg.sender]) revert NotExecutor();
        _;
    }

    modifier withPriceUpdate(bytes[] calldata priceUpdate) {
        if (priceUpdate.length != 0) {
            uint256 fee = pyth.getUpdateFee(priceUpdate);
            if (address(this).balance < fee) revert InsufficientUpdateFee();
            pyth.updatePriceFeeds{value: fee}(priceUpdate);
        }
        _;
    }

    function openPosition(OpenRequest calldata request, bytes calldata signature, bytes[] calldata priceUpdate)
        external
        payable
        onlyExecutor
        withPriceUpdate(priceUpdate)
        returns (uint256 positionId)
    {
        address trader = request.trader;
        _verifySignature(
            trader, keccak256(abi.encode(OPEN_POSITION_TYPEHASH, request)), request.nonce, request.deadline, signature
        );

        Instrument storage instrument = instruments[request.instrumentId];
        instrument.requireExists();

        uint256 debited = _debit(trader, request.collateral);
        Position memory p = Position({
            trader: trader,
            instrumentId: request.instrumentId,
            entryPrice: instrument.price(pyth, maxPriceAge).toUint64(),
            collateral: request.collateral,
            debited: debited.toUint128(),
            leverage: request.leverage,
            openedAt: uint64(block.timestamp),
            isLong: request.isLong,
            isOpen: true
        });
        p.validate(minCollateral, minNotional, collateralScale);

        positionId = nextPositionId++;
        positions[positionId] = p;
        openPositionIdsOf[trader].add(positionId);

        totalLockedMargin += p.collateral - debited;
        traderStats[trader].recordOpen(p.notional());
        totalStats.recordOpen(p.notional());

        emit PositionOpened(positionId, trader, p.instrumentId, p.isLong, p.entryPrice, p.collateral, p.leverage);
    }

    function closePositions(uint256[] calldata positionIds, bytes[] calldata priceUpdate)
        external
        payable
        withPriceUpdate(priceUpdate)
    {
        _closePositions(msg.sender, positionIds);
    }

    function closePositionsWithSig(
        CloseRequest calldata request,
        bytes calldata signature,
        bytes[] calldata priceUpdate
    ) external payable onlyExecutor withPriceUpdate(priceUpdate) {
        _verifySignature(
            request.trader,
            keccak256(
                abi.encode(
                    CLOSE_POSITIONS_TYPEHASH,
                    request.trader,
                    keccak256(abi.encodePacked(request.positionIds)),
                    request.nonce,
                    request.deadline
                )
            ),
            request.nonce,
            request.deadline,
            signature
        );
        _closePositions(request.trader, request.positionIds);
    }

    function liquidateBatch(uint256[] calldata positionIds, bytes[] calldata priceUpdate)
        external
        payable
        withPriceUpdate(priceUpdate)
    {
        uint256[] memory prices = new uint256[](instrumentCount);
        uint256 totalFees;
        for (uint256 i; i < positionIds.length; ++i) {
            totalFees += _tryLiquidate(positionIds[i], prices);
        }
        _payFee(owner(), totalFees);
    }

    function openPositionIds(address trader) external view returns (uint256[] memory) {
        return openPositionIdsOf[trader].values();
    }

    function liquidationPrice(uint256 positionId) external view returns (uint256) {
        Position memory p = positions[positionId];
        return p.liquidationPrice(instruments[p.instrumentId].config.liquidationBuffer);
    }

    function previewPnl(uint256 positionId, uint256 markPrice) external view returns (int256 rawPnl, int256 pnl) {
        Position memory p = positions[positionId];
        return p.pnl(markPrice, instruments[p.instrumentId].config);
    }

    function pythUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256) {
        return priceUpdate.length == 0 ? 0 : pyth.getUpdateFee(priceUpdate);
    }

    function setMaxPriceAge(uint256 maxPriceAge_) external onlyOwner {
        maxPriceAge = maxPriceAge_;
        emit MaxPriceAgeUpdated(maxPriceAge_);
    }

    function setExecutor(address executor, bool allowed) external onlyOwner {
        isExecutor[executor] = allowed;
        emit ExecutorUpdated(executor, allowed);
    }

    function setFeeRates(uint256 lossFeeRate_, uint256 winFeeRate_, uint256 liquidationFeeRate_) external onlyOwner {
        lossFeeRate = lossFeeRate_;
        winFeeRate = winFeeRate_;
        liquidationFeeRate = liquidationFeeRate_;

        emit FeeRatesUpdated(lossFeeRate_, winFeeRate_, liquidationFeeRate_);
    }

    function setTradeMinimums(uint256 minCollateral_, uint256 minNotional_) external onlyOwner {
        minCollateral = minCollateral_;
        minNotional = minNotional_;

        emit TradeMinimumsUpdated(minCollateral_, minNotional_);
    }

    function addInstrument(Config calldata config, string calldata symbol)
        external
        onlyOwner
        returns (uint32 instrumentId)
    {
        instrumentId = instrumentCount++;
        instruments[instrumentId].init(config);

        emit InstrumentAdded(instrumentId, config.priceId, symbol);
        emit InstrumentLiquidationBufferUpdated(instrumentId, config.liquidationBuffer);
        emit InstrumentHaircutConfigUpdated(
            instrumentId, config.moveScale, config.referenceSize, config.marketFactor, config.profitHaircut
        );
    }

    function setLiquidationBuffer(uint32 instrumentId, uint256 liquidationBuffer) external onlyOwner {
        instruments[instrumentId].setLiquidationBuffer(liquidationBuffer);
        emit InstrumentLiquidationBufferUpdated(instrumentId, liquidationBuffer);
    }

    function setHaircutConfig(
        uint32 instrumentId,
        uint256 moveScale,
        uint256 referenceSize,
        uint256 marketFactor,
        uint256 profitHaircut
    ) external onlyOwner {
        instruments[instrumentId].setHaircutConfig(moveScale, referenceSize, marketFactor, profitHaircut);
        emit InstrumentHaircutConfigUpdated(instrumentId, moveScale, referenceSize, marketFactor, profitHaircut);
    }

    receive() external payable {}

    function withdrawNative(address to, uint256 amount) external onlyOwner {
        Address.sendValue(payable(to), amount);
    }

    function _verifySignature(
        address trader,
        bytes32 structHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert SignatureExpired();
        _useCheckedNonce(trader, nonce);
        if (!SignatureChecker.isValidSignatureNow(trader, _hashTypedDataV4(structHash), signature)) {
            revert InvalidSignature();
        }
    }

    function _closePositions(address trader, uint256[] calldata positionIds) internal {
        uint256[] memory prices = new uint256[](instrumentCount);
        Settlement memory total;
        for (uint256 i; i < positionIds.length; ++i) {
            Settlement memory s = _tryClose(positionIds[i], trader, prices);
            total.returned += s.returned;
            total.owed += s.owed;
            total.lost += s.lost;
            total.fee += s.fee;
        }

        _settleNet(trader, total);
        _payFee(owner(), total.fee);
    }

    function _settleNet(address trader, Settlement memory s) internal {
        if (s.owed > s.lost) {
            _settleWin(trader, s.owed - s.lost);
        } else {
            _settleLoss(s.lost - s.owed);
        }

        uint256 direct = s.returned + Math.min(s.owed, s.lost);
        if (direct != 0) _pay(trader, direct);
    }

    function _tryClose(uint256 positionId, address trader, uint256[] memory prices)
        internal
        returns (Settlement memory s)
    {
        Position memory p = positions[positionId];
        if (!p.isOpen || p.trader != trader) return s;

        Instrument storage instrument = instruments[p.instrumentId];
        uint256 price = _cachedPrice(prices, p.instrumentId, instrument);
        uint256 cash = _release(positionId, p);

        (int256 rawPnl, int256 pnl) = p.pnl(price, instrument.config);
        if (pnl > 0) {
            uint256 profit = uint256(pnl);
            s.fee = (profit * winFeeRate) / WAD;
            s.returned = cash;
            s.owed = p.debited + profit - s.fee;
        } else {
            uint256 loss = uint256(-pnl);
            s.fee = (loss * lossFeeRate) / WAD;
            uint256 lossFromDebit = Math.min(loss, p.debited);
            s.lost = loss - lossFromDebit;
            s.returned = cash - s.lost;
            s.owed = p.debited - lossFromDebit;
        }
        traderStats[p.trader].recordClose(pnl, s.fee);
        totalStats.recordClose(pnl, s.fee);
        emit PositionClosed(positionId, p.trader, price, rawPnl, pnl, s.fee);
    }

    function _tryLiquidate(uint256 positionId, uint256[] memory prices) internal returns (uint256 fee) {
        Position memory p = positions[positionId];
        if (!p.isOpen) return 0;

        Instrument storage instrument = instruments[p.instrumentId];
        uint256 price = _cachedPrice(prices, p.instrumentId, instrument);
        (bool liquidatable, uint256 liqPrice) = p.isLiquidatable(price, instrument.config.liquidationBuffer);
        if (!liquidatable) return 0;

        uint256 cash = _release(positionId, p);
        if (cash != 0) _settleLoss(cash);
        fee = (p.collateral * liquidationFeeRate) / WAD;
        traderStats[p.trader].recordLiquidation(p.collateral, fee);
        totalStats.recordLiquidation(p.collateral, fee);
        emit Liquidated(positionId, p.trader, price, liqPrice, fee);
    }

    function _release(uint256 positionId, Position memory p) internal returns (uint256 cash) {
        cash = p.collateral - p.debited;

        positions[positionId].isOpen = false;
        totalLockedMargin -= cash;
        openPositionIdsOf[p.trader].remove(positionId);
    }

    function _cachedPrice(uint256[] memory prices, uint32 instrumentId, Instrument storage instrument)
        internal
        view
        returns (uint256)
    {
        if (prices[instrumentId] == 0) {
            prices[instrumentId] = instrument.price(pyth, maxPriceAge);
        }
        return prices[instrumentId];
    }
}
