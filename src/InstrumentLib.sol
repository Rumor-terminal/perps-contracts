// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

uint256 constant WAD = 1e18;

struct Config {
    bytes32 priceId;
    uint256 maxLeverage;
    uint256 maxNotional;
    uint256 liquidationBuffer;
    uint256 impactA;
    uint256 impactB;
    uint256 impactC;
    uint256 profitHaircut;
}

struct Oi {
    uint128 longSize;
    uint128 shortSize;
    uint128 longCap;
    uint128 shortCap;
}

struct Instrument {
    Config config;
    Oi oi;
}

library InstrumentLib {
    using SafeCast for uint256;

    error InvalidInstrumentConfig();
    error InvalidInstrumentId();
    error LeverageTooHigh();
    error PositionTooLarge();
    error OiCapExceeded();
    error InvalidPrice();

    uint8 internal constant PRICE_DECIMALS = 8;
    uint256 internal constant PRICE_SCALE = 10 ** PRICE_DECIMALS;
    int32 internal constant PRICE_EXPO = -int32(uint32(PRICE_DECIMALS));

    function init(Instrument storage self, Config calldata config) internal {
        if (config.priceId == bytes32(0)) revert InvalidInstrumentConfig();

        self.config.priceId = config.priceId;
        setRiskParams(self, config.maxLeverage, config.maxNotional, config.liquidationBuffer);
        setImpactConfig(self, config.impactA, config.impactB, config.impactC, config.profitHaircut);

        self.oi.longCap = type(uint128).max;
        self.oi.shortCap = type(uint128).max;
    }

    function requireExists(Instrument storage self) internal view {
        if (self.config.priceId == bytes32(0)) revert InvalidInstrumentId();
    }

    function setRiskParams(Instrument storage self, uint256 maxLeverage, uint256 maxNotional, uint256 liquidationBuffer)
        internal
    {
        requireExists(self);
        if (maxLeverage == 0 || maxNotional == 0 || liquidationBuffer >= WAD) {
            revert InvalidInstrumentConfig();
        }

        self.config.maxLeverage = maxLeverage;
        self.config.maxNotional = maxNotional;
        self.config.liquidationBuffer = liquidationBuffer;
    }

    function setImpactConfig(
        Instrument storage self,
        uint256 impactA,
        uint256 impactB,
        uint256 impactC,
        uint256 profitHaircut
    ) internal {
        requireExists(self);
        if (impactA == 0 || impactC == 0 || profitHaircut >= WAD) {
            revert InvalidInstrumentConfig();
        }

        self.config.impactA = impactA;
        self.config.impactB = impactB;
        self.config.impactC = impactC;
        self.config.profitHaircut = profitHaircut;
    }

    function setOiCaps(Instrument storage self, uint128 longCap, uint128 shortCap) internal {
        requireExists(self);

        self.oi.longCap = longCap;
        self.oi.shortCap = shortCap;
    }

    function validateOpenPosition(Instrument storage self, uint256 collateral, uint256 leverage) internal view {
        requireExists(self);
        if (leverage > self.config.maxLeverage) revert LeverageTooHigh();
        if (collateral * leverage > self.config.maxNotional) revert PositionTooLarge();
    }

    function increaseOi(Instrument storage self, bool isLong, uint256 size) internal {
        Oi storage oi = self.oi;

        if (isLong) {
            uint256 newLong = oi.longSize + size;
            if (newLong > oi.longCap) revert OiCapExceeded();
            oi.longSize = newLong.toUint128();
        } else {
            uint256 newShort = oi.shortSize + size;
            if (newShort > oi.shortCap) revert OiCapExceeded();
            oi.shortSize = newShort.toUint128();
        }
    }

    function decreaseOi(Instrument storage self, bool isLong, uint256 size) internal {
        if (isLong) self.oi.longSize -= size.toUint128();
        else self.oi.shortSize -= size.toUint128();
    }

    function price(Instrument storage self, IPyth pyth, uint256 maxPriceAge) internal view returns (uint256) {
        PythStructs.Price memory p = pyth.getPriceNoOlderThan(self.config.priceId, maxPriceAge);
        return normalizePrice(p.price, p.expo);
    }

    function normalizePrice(int64 rawPrice, int32 expo) internal pure returns (uint256 value) {
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
