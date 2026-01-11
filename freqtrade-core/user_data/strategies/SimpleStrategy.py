# pragma pylint: disable=missing-docstring, invalid-name
# flake8: noqa: F401

import talib.abstract as ta
from pandas import DataFrame
from freqtrade.strategy import IStrategy
from technical import qtpylib


class SimpleStrategy(IStrategy):
    """
    A minimal EMA crossover strategy for demo/training use.
    """

    INTERFACE_VERSION = 3
    can_short = False

    minimal_roi = {"0": 0.02}
    stoploss = -0.05
    timeframe = "5m"
    startup_candle_count = 30

    def populate_indicators(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        dataframe["ema_fast"] = ta.EMA(dataframe, timeperiod=9)
        dataframe["ema_slow"] = ta.EMA(dataframe, timeperiod=21)
        dataframe["rsi"] = ta.RSI(dataframe, timeperiod=14)
        return dataframe

    def populate_entry_trend(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        dataframe.loc[
            (
                qtpylib.crossed_above(dataframe["ema_fast"], dataframe["ema_slow"])
                & (dataframe["rsi"] > 50)
                & (dataframe["volume"] > 0)
            ),
            "enter_long",
        ] = 1
        return dataframe

    def populate_exit_trend(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        dataframe.loc[
            (
                qtpylib.crossed_below(dataframe["ema_fast"], dataframe["ema_slow"])
                | (dataframe["rsi"] > 70)
            )
            & (dataframe["volume"] > 0),
            "exit_long",
        ] = 1
        return dataframe
