// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library InstrumentLib {
    using SafeCast for uint256;

    error InvalidInstrumentConfig();
    error InvalidSizeScale();
    error InvalidInstrumentId();
    error LeverageTooLow();
    error LeverageTooHigh();
    error PositionTooLarge();
    error TradeBelowMinimum();
    error NotionalBelowMinimum();
    error OiCapExceeded();
    error InvalidPrice();

    uint256 internal constant WAD = 1e18;
    int32 internal constant PRICE_EXPO = -8;

    struct Config {
        uint256 impactA;
        uint256 impactB;
        bytes32 priceId;
        uint256 maxLeverage;
        uint256 maxNotional;
        uint256 liquidationBuffer;
        uint256 profitHaircut;
        uint256 impactC;
    }

    struct Oi {
        uint96 longSize;
        uint96 shortSize;
        uint64 sizeScale;
        uint96 longCap;
        uint96 shortCap;
    }

    struct Instrument {
        Config config;
        Oi oi;
    }

    function init(
        Instrument storage self,
        Config calldata config,
        uint64 sizeScale
    ) internal {
        if (
            config.maxLeverage == 0 ||
            config.liquidationBuffer >= WAD ||
            config.profitHaircut >= WAD ||
            config.impactA == 0 ||
            config.impactC == 0 ||
            config.maxNotional == 0 ||
            config.priceId == bytes32(0)
        ) revert InvalidInstrumentConfig();
        if (sizeScale == 0) revert InvalidSizeScale();
        self.config = config;
        self.oi.sizeScale = sizeScale;
        self.oi.longCap = type(uint96).max;
        self.oi.shortCap = type(uint96).max;
    }

    function requireExists(Instrument storage self) internal view {
        if (self.config.priceId == bytes32(0)) {
            revert InvalidInstrumentId();
        }
    }

    function setRiskParams(
        Instrument storage self,
        uint256 maxLeverage,
        uint256 maxNotional
    ) internal {
        requireExists(self);
        if (maxLeverage == 0 || maxNotional == 0) {
            revert InvalidInstrumentConfig();
        }
        self.config.maxLeverage = maxLeverage;
        self.config.maxNotional = maxNotional;
    }

    function setImpactConfig(
        Instrument storage self,
        uint256 impactC,
        uint256 impactB,
        uint256 impactA,
        uint256 profitHaircut
    ) internal {
        requireExists(self);
        if (impactC == 0 || impactA == 0 || profitHaircut >= WAD) {
            revert InvalidInstrumentConfig();
        }
        self.config.impactC = impactC;
        self.config.impactB = impactB;
        self.config.impactA = impactA;
        self.config.profitHaircut = profitHaircut;
    }

    function setOiCaps(
        Instrument storage self,
        uint96 longCap,
        uint96 shortCap
    ) internal {
        requireExists(self);
        self.oi.longCap = longCap;
        self.oi.shortCap = shortCap;
    }

    function checkOpen(
        Instrument storage self,
        uint256 collateral,
        uint256 leverage,
        uint256 minCollateral,
        uint256 minNotional
    ) internal view {
        requireExists(self);
        if (leverage == 0) revert LeverageTooLow();
        if (leverage > self.config.maxLeverage) {
            revert LeverageTooHigh();
        }
        uint256 notional = collateral * leverage;
        if (notional > self.config.maxNotional) {
            revert PositionTooLarge();
        }
        if (collateral < minCollateral) revert TradeBelowMinimum();
        if (notional < minNotional) revert NotionalBelowMinimum();
    }

    function increaseOi(
        Instrument storage self,
        bool isLong,
        uint256 size
    ) internal {
        Oi storage oi = self.oi;
        if (isLong) {
            uint256 newLong = oi.longSize + size;
            if (newLong > oi.longCap) revert OiCapExceeded();
            oi.longSize = newLong.toUint96();
        } else {
            uint256 newShort = oi.shortSize + size;
            if (newShort > oi.shortCap) revert OiCapExceeded();
            oi.shortSize = newShort.toUint96();
        }
    }

    function decreaseOi(
        Instrument storage self,
        bool isLong,
        uint256 size
    ) internal {
        if (isLong) self.oi.longSize -= size.toUint96();
        else self.oi.shortSize -= size.toUint96();
    }

    function price(
        Instrument storage self,
        IPyth pyth,
        uint256 maxPriceAge
    ) internal view returns (uint256) {
        PythStructs.Price memory p = pyth.getPriceNoOlderThan(
            self.config.priceId,
            maxPriceAge
        );
        return normalizePrice(p.price, p.expo);
    }

    function normalizePrice(
        int64 rawPrice,
        int32 expo
    ) internal pure returns (uint256 value) {
        if (rawPrice <= 0) revert InvalidPrice();
        value = uint256(uint64(rawPrice));
        if (expo < PRICE_EXPO) {
            value /= 10 ** uint256(uint32(PRICE_EXPO - expo));
        } else if (expo > PRICE_EXPO) {
            value *= 10 ** uint256(uint32(expo - PRICE_EXPO));
        }
        if (value == 0) revert InvalidPrice();
    }
}
