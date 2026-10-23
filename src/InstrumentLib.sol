// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

uint256 constant WAD = 1e18;

struct Config {
    bytes32 priceId;
    uint256 liquidationBuffer;
    uint256 moveScale;
    uint256 referenceSize;
    uint256 marketFactor;
    uint256 profitHaircut;
}

struct Instrument {
    Config config;
}

library InstrumentLib {
    using SafeCast for uint256;

    error InvalidInstrumentConfig();
    error InvalidInstrumentId();
    error InvalidPrice();

    uint8 internal constant PRICE_DECIMALS = 8;
    uint256 internal constant PRICE_SCALE = 10 ** PRICE_DECIMALS;
    int32 internal constant PRICE_EXPO = -int32(uint32(PRICE_DECIMALS));

    function init(Instrument storage self, Config calldata config) internal {
        if (config.priceId == bytes32(0)) revert InvalidInstrumentConfig();

        self.config.priceId = config.priceId;
        setLiquidationBuffer(self, config.liquidationBuffer);
        setHaircutConfig(self, config.moveScale, config.referenceSize, config.marketFactor, config.profitHaircut);
    }

    function requireExists(Instrument storage self) internal view {
        if (self.config.priceId == bytes32(0)) revert InvalidInstrumentId();
    }

    function setLiquidationBuffer(Instrument storage self, uint256 liquidationBuffer) internal {
        requireExists(self);
        if (liquidationBuffer >= WAD) revert InvalidInstrumentConfig();

        self.config.liquidationBuffer = liquidationBuffer;
    }

    function setHaircutConfig(
        Instrument storage self,
        uint256 moveScale,
        uint256 referenceSize,
        uint256 marketFactor,
        uint256 profitHaircut
    ) internal {
        requireExists(self);
        if (moveScale == 0 || marketFactor == 0 || profitHaircut >= WAD) {
            revert InvalidInstrumentConfig();
        }

        self.config.moveScale = moveScale;
        self.config.referenceSize = referenceSize;
        self.config.marketFactor = marketFactor;
        self.config.profitHaircut = profitHaircut;
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
