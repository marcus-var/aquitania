########################################################################################################################
# |||||||||||||||||||||||||||||||||||||||||||||||||| AQUITANIA ||||||||||||||||||||||||||||||||||||||||||||||||||||||| #
# |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||| #
# |||| To be a thinker means to go by the factual evidence of a case, not by the judgment of others |||||||||||||||||| #
# |||| As there is no group stomach to digest collectively, there is no group mind to think collectively. |||||||||||| #
# |||| Each man must accept responsibility for his own life, each must be sovereign by his own judgment. ||||||||||||| #
# |||| If a man believes a claim to be true, then he must hold to this belief even though society opposes him. ||||||| #
# |||| Not only know what you want, but be willing to break all established conventions to accomplish it. |||||||||||| #
# |||| The merit of a design is the only credential that you require. |||||||||||||||||||||||||||||||||||||||||||||||| #
# |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||| #
########################################################################################################################

"""
.. moduleauthor:: H Roark
"""
import pandas as pd
import numpy as np
import os
import multiprocessing

from aquitania.data_processing.analytics_loader import build_liquidation_dfs


cpdef void build_exits(broker_instance, str asset, signal, int max_candles, bint is_dentro=False, bint is_virada=False):
    """
    Calculates exit DateTime for a list of Exit Points. It will be used in later module that evaluates winning or
    losing positions.

    :param broker_instance: (DataSource) Input broker instance
    :param asset: (str) Input asset
    :param signal: (AbstractSignal) Input signal
    :param max_candles: (int) Number of max G01 candles to look in the future to liquidate trade
    :param is_dentro: (bool) True if when positioned, don't look for new positions in the same side
    :param is_virada: (bool) True if when positioned, if there is a trade in the same side, you switch positions
    """

    # Initializes variables
    entry = signal.entry
    exit_points = {signal.stop, signal.profit}
    exits = None

    df, candles_df = build_dfs(broker_instance, asset, exit_points, entry)
    exits = process_exit_points(df, exit_points, candles_df, max_candles, is_virada)

    # Save liquidation to disk
    save_liquidation_to_disk(asset, entry, exits)

    consolidate_exits(asset, entry, exits)

cdef build_dfs(broker_instance, asset, exit_points, entry):
    # Load DataFrames
    df = build_liquidation_dfs(broker_instance, asset, exit_points, entry)
    candles_df = broker_instance.load_data(asset)

    # Create Entry Point column
    candles_df['entry_point'] = candles_df['open'].shift(-1)

        # Build entry points and close values into exit DataFrame
    df = build_entry_points(df, candles_df)

    # Checks if df is empty and raise Warning if so.
    if df.shape[0] == 0:
        ValueError('There was a problem with the signal in your strategy, it didn\'t generate any ok=True.')

    # Clean Candles DF
    candles_df = candles_df[['open', 'high', 'low']]

    return df, candles_df

cdef process_exit_points(df, set exit_points, candles_df, int max_candles, bint is_virada):
    # Create exits for all exit points
    for exit_point in exit_points:
        # Separate Alta and Baixa
        df_alta = df[df[exit_point] > 0].copy()
        df_baixa = df[df[exit_point] < 0].copy()

        print('aa')
        print(df_alta.shape)
        print(df_baixa.shape)

        # Invert Baixa values
        df_baixa[exit_point] = df_baixa[exit_point] * -1

        # Run multiprocessing routine
        exit_point = exit_point
        exit_baixo = multiprocessing(df_alta, exit_point, candles_df, max_candles)
        exit_cima = multiprocessing(df_baixa, exit_point, candles_df, max_candles)

        # Routine for df_alta
        # exit_baixo = df_alta.apply(self.create_exits, axis=1)
        exit_baixo.columns = [exit_point + '_dt', exit_point + '_saldo']

        # Routine for df_baixa
        # exit_cima = df_baixa.apply(self.create_exits, axis=1)
        exit_cima.columns = [exit_point + '_dt', exit_point + '_saldo']

        # Concat exits
        if exits is None:
            exits = pd.concat([exit_cima, exit_baixo])
        else:
            exits = pd.concat([exits, pd.concat([exit_cima, exit_baixo])], axis=1)
        # Routine if for every trade an opposite trade is automatically an entry

    if is_virada:
        virada_df = virada(df)
        exits = pd.concat([exits, virada_df], axis=1)

    # Quick fix to generate entry points for AI
    else:
        temp_df = df[['entry_point']]
        temp_df.columns = ['entry']
        exits = pd.concat([exits, temp_df], axis=1)

    return exits

def build_entry_points(df, candles_df):
    """
    The new feeder routine that was created to deal with the issue that there were outputted candles that were not
    in the right possible timing, which helped remove the .update_method() from indicator logic, need to have a fix
    because we will have output at TimeStamps that have never existing in 1 Minute candles.

    For this reason some kind of routine was needed to fetch those trades that were created in minutes that are not
    part of the original Database.

    :param df: (pandas DataFrame) Containing exit points.

    :return: DataFrame with exit points along with close and entry_point values
    :rtype: pandas DataFrame
    """

    # Generates inner join DataFrame
    df_inner = pd.concat([candles_df[['close', 'entry_point']], df], join='inner', axis=1)

    # Finds exit points for elements outside the inner join DataFrame
    for element in df.index.difference(df_inner.index):
        # Selects 1 month prior to the DataFrame, which is the highest period we use
        w = candles_df.loc[element - pd.offsets.Day(31):element + pd.offsets.Minute(1)].iloc[-1][
            ['close', 'entry_point']]

        # Changes index to be able to concat correctly
        w.name = element

        # Creates line to be added
        x = pd.concat([df.loc[element], w])

        # Add line to DataFrame
        df_inner.loc[element] = x

    # Returns ordered DataFrame
    return df_inner.sort_index()


def multiprocessing(df, exit_point, candles_df, max_candles):
    cpu = 16 # TODO improve cpu count routine
    dividers = [int(df.shape[0] / cpu * i) for i in range(1, cpu)]

    df_list = np.split(df, dividers, axis=0)

    pool = multiprocessing.Pool()
    # TODO how to pass args into pool.map()
    results = pool.map(dataframe_apply, df_list)
    pool.close()
    pool.join()

    # Filter to remove df with zero rows
    results = [df for df in results if df.shape[0] > 0]

    x = pd.concat(results)[[0, 1]]
    return x


def dataframe_apply(df, exit_point, candles_df, max_candles):
    for x, y, *z in df.itertuples():
        create_exits(x, exit_point, candles_df, max_candles)
    # TODO try rewriting with itertuples to verify if it is faster?
    return df.apply(create_exits, axis=1, args=(exit_point, candles_df, max_candles))


def create_exits(df_line, exit_point, candles_df, max_candles):
    """
    Calculate exit datetime for each possible exit point.

    :param df_line: Input df_line

    :return: pd.Series([Hora da Saida, Saldo])
    """
    exit_point = exit_point

    # Evaluate if it is stop or not
    if 'stop' in exit_point:
        is_stop = True
    else:
        is_stop = False

    # Evaluate if alta ou baixa
    if df_line.close > df_line[exit_point]:
        is_high = False
    else:
        is_high = True

    # Gets Exit Quote
    exit_quote = df_line[exit_point]

    # Select remaining DataFrame
    remaining = candles_df.loc[df_line.name:]

    # Checks if it is not the last value
    if remaining.shape[0] < 2:
        # Need to return series as this outputs a DataFrame when used in a DF.apply()
        return pd.Series([np.datetime64('NaT'), 0.0])

    # First row instantiation
    first_row = remaining.index[0]

    # Iter through DataFrame to find exit

    for index, open, high, low in remaining[0:1].itertuples():

        # Routine if high
        if is_high:
            if high >= exit_quote:
                if index == first_row:
                    if open >= exit_quote:
                        return pd.Series([np.datetime64('NaT'), -1.0])

        # Routine if low
        else:
            if low <= exit_quote:
                if index == first_row:
                    if open <= exit_quote:
                        return pd.Series([np.datetime64('NaT'), -1.0])

    # Select all rows but self
    remaining = remaining.iloc[1:max_candles]

    # Iter through DataFrame to find exit
    for index, open, high, low in remaining.itertuples():

        # Routine if high
        if is_high:
            if high >= exit_quote:
                exit_quote = max(open, exit_quote)
                saldo = exit_quote - df_line['entry_point']

                if is_stop:
                    saldo = saldo * -1
                return pd.Series([index, saldo])

        # Routine if low
        else:
            if low <= exit_quote:
                exit_quote = min(open, exit_quote)
                saldo = df_line['entry_point'] - exit_quote

                if is_stop:
                    saldo = saldo * -1
                return pd.Series([index, saldo])

    # If no values found returns blank
    return pd.Series([np.datetime64('NaT'), 0.0])


def consolidate_exits(asset, entry, exits):
    """
    Run exit consolidation routine and saves it to disk.
    """
    # Sort DataFrame
    exits.sort_index(inplace=True)

    # Instantiates DataFrame
    df = exits.apply(juntate_exits, axis=1)
    df.columns = ['exit_reference', 'exit_date', 'exit_saldo']

    # Sets filename
    filename = 'data/liquidation/' + asset + '_' + entry + '_CONSOLIDATE'

    # Save liquidation to disk
    save_liquidation_to_disk(filename, df)


def juntate_exits(df_line, is_dentro):
    """
    Gets a DataFrame line and evaluate what exit will it be.

    :param df_line: Input DF Line
    :return: Output DF Line containing:
        1. 'exit_reference' - String
        2. 'exit_date' - DateTime
        3. 'exit_saldo' - Float
    :rtype: pandas Series
    """
    # TODO evaluate last_trade logic
    last_trade = None

    # Dentro Routine
    if is_dentro and last_trade is not None and last_trade > df_line.name:
        return pd.Series(['', np.datetime64('NaT'), 0])

    # Creates DataFrame to be able to use select_dtypes function
    df = pd.DataFrame([df_line])

    if check_if_invalid_entry(df):
        return pd.Series(['', np.datetime64('NaT'), 0])

    # Select only dates
    include_dict = {'include' : np.datetime64}  # Needed to bypass something in cython
    df = df.select_dtypes(**include_dict)

    # Select minimum dates
    selected_column = df.idxmin(axis=1).values[0]

    # If dates returns empty return empty
    if isinstance(selected_column, np.float64):
        return pd.Series(['', np.datetime64('NaT'), 0])

    # Get saldo column name
    selected_saldo = selected_column.replace('dt', 'saldo')

    last_trade = df_line[selected_column]

    # Generates output
    return pd.Series([selected_column, df_line[selected_column], df_line[selected_saldo]])


def check_if_invalid_entry(df_line):
    if not df_line.isin([-1]).values.any():
        return False
    else:
        selected_columns = df_line.columns[df_line.isin([-1]).values[0]]
        for column in selected_columns:
            selected_dt = column.replace('saldo', 'dt')
            if pd.isnull(df_line[selected_dt].values):
                return True
    return False


def save_liquidation_to_disk(asset, entry, df):
    """
    Saves liquidation to disk in HDF5 format.

    :param filename: Selects filename to be saved
    :param df: DataFrame to be saved
    """

    # Sets filename
    filename = 'data/liquidation/' + asset + '_' + entry


    # Remove liquidation File if exists
    if os.path.isfile(filename):
        os.unlink(filename)

    # Save liquidations to disk
    with pd.HDFStore(filename) as hdf:
        hdf.append(key='liquidation', value=df, format='table', data_columns=True)


def virada(df):
    # TODO virada is dependent on column order. improve this.
    output = []
    for index_a, close_a, ep_a, profit_a, stop_a in df.itertuples():
        for index_b, close_b, ep_b, profit_b, stop_b in df[index_a:].itertuples():
            if stop_a > 0:
                if stop_b < 0:
                    output.append([index_b, ep_b - ep_a, ep_a])
                    break
            else:
                if stop_b > 0:
                    output.append([index_b, ep_a - ep_b, ep_a])
                    break
        else:
            output.append([np.datetime64('NaT'), 0.0, ep_a])

    return pd.DataFrame(output, index=df.index, columns=['virada_dt', 'virada_saldo', 'entry'])