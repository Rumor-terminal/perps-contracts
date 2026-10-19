// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

library InstrumentLib {
    error InvalidInstrumentConfig();
    error InvalidSizeScale();
    error InvalidInstrumentId();
    error LeverageTooLow();
    error LeverageTooHigh();
    error PositionTooLarge();
    error OiCapExceeded();
    error InvalidPrice();

    uint256 internal constant WAD = 1e18;
    int32 internal constant PRICE_EXPO = -8;

    struct Config {
        uint96 impactA;
        uint96 impactB;
        bytes32 priceId;
        uint32 maxLeverage;
        uint120 maxNotional;
        uint64 liquidationBuffer;
        uint64 profitHaircut;
        uint128 impactC;
    }

    struct Oi {
        uint96 longSize;
        uint96 shortSize;
        uint64 sizeScale;
        uint128 longCap;
        uint128 shortCap;
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
        self.oi.longCap = type(uint128).max;
        self.oi.shortCap = type(uint128).max;
    }

    function requireExists(Instrument storage self) internal view {
        if (self.config.priceId == bytes32(0)) {
            revert InvalidInstrumentId();
        }
    }

    function setRisk(
        Instrument storage self,
        uint32 maxLeverage,
        uint256 maxNotional
    ) internal {
        requireExists(self);
        if (
            maxLeverage == 0 ||
            maxNotional == 0 ||
            maxNotional > type(uint120).max
        ) {
            revert InvalidInstrumentConfig();
        }
        self.config.maxLeverage = maxLeverage;
        self.config.maxNotional = uint120(maxNotional);
    }

    function setImpactConfig(
        Instrument storage self,
        uint128 impactC,
        uint96 impactB,
        uint96 impactA,
        uint64 profitHaircut
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
        uint128 longCap,
        uint128 shortCap
    ) internal {
        requireExists(self);
        self.oi.longCap = longCap;
        self.oi.shortCap = shortCap;
    }

    function checkOpen(
        Instrument storage self,
        uint128 collateral,
        uint32 leverage
    ) internal view returns (uint256 notional) {
        requireExists(self);
        if (leverage == 0) revert LeverageTooLow();
        if (leverage > self.config.maxLeverage) {
            revert LeverageTooHigh();
        }
        notional = uint256(collateral) * leverage;
        if (notional > self.config.maxNotional) {
            revert PositionTooLarge();
        }
    }

    function increaseOi(
        Instrument storage self,
        bool isLong,
        uint96 size
    ) internal {
        Oi storage oi = self.oi;
        if (isLong) {
            uint96 newLong = oi.longSize + size;
            if (newLong > oi.longCap) revert OiCapExceeded();
            oi.longSize = newLong;
        } else {
            uint96 newShort = oi.shortSize + size;
            if (newShort > oi.shortCap) revert OiCapExceeded();
            oi.shortSize = newShort;
        }
    }

    function decreaseOi(
        Instrument storage self,
        bool isLong,
        uint96 size
    ) internal {
        if (isLong) self.oi.longSize -= size;
        else self.oi.shortSize -= size;
    }

    function price(
        Instrument storage self,
        IPyth pyth,
        uint256 maxPriceAge
    ) internal view returns (uint64) {
        PythStructs.Price memory p = pyth.getPriceNoOlderThan(
            self.config.priceId,
            maxPriceAge
        );
        return normalizePrice(p.price, p.expo);
    }

    function normalizePrice(
        int64 rawPrice,
        int32 expo
    ) internal pure returns (uint64) {
        if (rawPrice <= 0) revert InvalidPrice();
        uint256 value = uint256(uint64(rawPrice));
        if (expo < PRICE_EXPO) {
            value /= 10 ** uint256(uint32(PRICE_EXPO - expo));
        } else if (expo > PRICE_EXPO) {
            value *= 10 ** uint256(uint32(expo - PRICE_EXPO));
        }
        if (value == 0 || value > type(uint64).max) {
            revert InvalidPrice();
        }
        return uint64(value);
    }
}
