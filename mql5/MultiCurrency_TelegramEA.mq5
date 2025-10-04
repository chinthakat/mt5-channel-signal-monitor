//+------------------------------------------------------------------+
//| MultiCurrency_TelegramEA.mq5                                     |
//|                                                                  |
//| Multi-symbol Expert Advisor. Runs on any one chart and polls a   |
//| single aggregate signal file (SignalFileName, default            |
//| multicurrency_signals.json) in the MetaTrader 5 shared           |
//| Common\Files folder every TimerSeconds. The file is written by   |
//| an external producer that is not part of this project and is     |
//| shaped as                                                        |
//|   {"timestamp": "...", "signals": {"EURUSD": {...}, ...}}        |
//| The top-level timestamp is the de-duplication key: an unchanged  |
//| timestamp means the file is skipped.                             |
//|                                                                  |
//| Each entry under "signals" whose symbol appears in               |
//| AllowedSymbols is acted on: buy/sell open a market position      |
//| sized from RiskPercent of balance over the SL distance, close    |
//| closes it, update_sl/update_tp modify it. Open positions are     |
//| moved to breakeven and then trailed on every timer tick, and     |
//| new trading stops for the day once MaxDailyLoss percent of the   |
//| day's starting balance has been lost.                            |
//|                                                                  |
//| Output goes to the terminal's Experts log only; this EA writes   |
//| no file. See README.md for the input reference and JSON schema.  |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.01"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade trade;
CPositionInfo position;

input string SignalFileName           = "multicurrency_signals.json"; // Multi-currency signal file
input string CommonFilesDir           = "";                   // Optional absolute path; usually leave empty
input double RiskPercent              = 1.0;                  // % of balance to risk per trade
input double MaxRiskPercent           = 5.0;                  // Maximum risk per trade (safety limit)
input double MaxDailyLoss             = 10.0;                // Max daily loss % to stop trading
input int    MaxSlippagePoints        = 50;                   // Max slippage in points
input long   MagicNumber              = 20250814;             // Magic number to tag positions
input bool   ManageOnlyOurPositions   = true;                 // Only manage positions with our Magic
input int    TimerSeconds             = 3;                    // Polling interval seconds
input bool   EnableNewsFilter         = false;                // Stop trading during high impact news
// New: Breakeven and Trailing
input bool   EnableBreakeven          = true;                 // Move SL to BE after profit
input int    BreakevenTriggerPoints   = 300;                  // Profit in points to trigger BE (reduced for forex)
input int    BreakevenOffsetPoints    = 20;                   // Extra points beyond entry for BE
input bool   EnableTrailingStop       = true;                 // Apply trailing after BE
input int    TrailStartPoints         = 400;                  // Start trailing after this profit (points)
input int    TrailStepPoints          = 100;                  // Keep SL at price -/+ this distance
// Symbol whitelist
input string AllowedSymbols           = "EURUSD,GBPUSD,USDJPY,USDCHF,AUDUSD,USDCAD,NZDUSD,EURJPY,GBPJPY,EURGBP,AUDCAD,GBPCAD,EURAUD,EURCHF,AUDCHF,CADCHF,NZDCAD,AUDNZD,EURNZD,GBPNZD,XAUUSD,XAGUSD"; // Comma-separated list

string g_last_timestamp = "";
double g_daily_start_balance = 0.0;
datetime g_last_balance_reset = 0;
string g_allowed_symbols[];
int g_symbol_count = 0;

int OnInit()
{
   Print("=== Multi-Currency Telegram EA Initialization ===");
   
   trade.SetExpertMagicNumber((int)MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   Print("Trade object configured with Magic Number: ", MagicNumber, ", Max Slippage: ", MaxSlippagePoints);
   
   EventSetTimer(TimerSeconds);
   PrintFormat("Timer set to %d seconds polling interval", TimerSeconds);
   
   // Initialize daily balance tracking
   g_daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_last_balance_reset = TimeCurrent();
   PrintFormat("Daily balance tracking initialized. Starting balance: %.2f", g_daily_start_balance);
   
   // Parse allowed symbols
   ParseAllowedSymbols();
   
   // Validate risk parameters
   double risk_pct = RiskPercent;
   if(risk_pct <= 0.0 || risk_pct > MaxRiskPercent)
   {
      PrintFormat("Invalid RiskPercent: %f. Using 1.0%%", risk_pct);
      risk_pct = 1.0;
   }
   
   Print("Multi-currency signal file monitoring: ", SignalFileName);
   if(CommonFilesDir != "")
      Print("Alternative directory: ", CommonFilesDir);
   PrintFormat("Monitoring %d symbols: %s", g_symbol_count, AllowedSymbols);
   PrintFormat("Risk Management: %.2f%% per trade, Max %.2f%% daily loss", risk_pct, MaxDailyLoss);
   PrintFormat("Breakeven: %s (trigger: %d points, offset: %d points)", 
               EnableBreakeven ? "Enabled" : "Disabled", BreakevenTriggerPoints, BreakevenOffsetPoints);
   PrintFormat("Trailing Stop: %s (start: %d points, step: %d points)", 
               EnableTrailingStop ? "Enabled" : "Disabled", TrailStartPoints, TrailStepPoints);
   
   Print("=== Multi-Currency EA Initialization Complete ===");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTick() { /* not used; we poll in OnTimer */ }

void OnTimer()
{
   // Check daily loss limit
   if(!CheckDailyLossLimit())
   {
      Print("Daily loss limit reached. Stopping trading for today.");
      return;
   }

   // Apply risk management on all active positions
   ApplyBreakevenAndTrailingAll();

   // Read multi-currency signal file
   Print("Reading multi-currency signal file: ", SignalFileName);
   string json = ReadSignalJson();
   
   if(json == "")
   {
      Print("Multi-currency signal file is empty or not found");
      return;
   }
   
   Print("Multi-currency signal file content: ", json);

   string timestamp;
   if(!ExtractString(json, "timestamp", timestamp))
   {
      Print("No timestamp found in signal file");
      return;
   }
   
   if(timestamp == g_last_timestamp)
   {
      Print("Signals already processed (same timestamp): ", timestamp);
      return; // already processed
   }
   
   Print("New signals detected with timestamp: ", timestamp);

   // Process all signals in the file
   ProcessMultiCurrencySignals(json);

   if(timestamp != "")
   {
      g_last_timestamp = timestamp;
      Print("Signal processing completed. Last processed timestamp updated to: ", timestamp);
   }
}

void ProcessMultiCurrencySignals(const string json)
{
   Print("Processing multi-currency signals...");
   
   // Extract signals object
   string signals_json = ExtractSignalsObject(json);
   if(signals_json == "")
   {
      Print("No signals object found in JSON");
      return;
   }
   
   Print("Extracted signals object: ", signals_json);
   
   // Process each symbol's signal
   for(int i = 0; i < g_symbol_count; i++)
   {
      string symbol = g_allowed_symbols[i];
      ProcessSymbolSignal(signals_json, symbol);
   }
}

void ProcessSymbolSignal(const string signals_json, const string symbol)
{
   // Look for this symbol's signal in the signals object
   string symbol_signal = ExtractSymbolSignal(signals_json, symbol);
   if(symbol_signal == "")
   {
      // No signal for this symbol
      return;
   }
   
   PrintFormat("Processing signal for %s: %s", symbol, symbol_signal);
   
   // Extract signal details
   string action;
   if(!ExtractStringFromSignal(symbol_signal, "action", action))
   {
      PrintFormat("No action found for %s", symbol);
      return;
   }
   
   double price = 0.0;
   double sl = 0.0;
   double tp = 0.0;
   
   ExtractDoubleFromSignal(symbol_signal, "price", price);
   ExtractDoubleFromSignal(symbol_signal, "sl", sl);
   ExtractDoubleFromSignal(symbol_signal, "tp", tp);
   
   PrintFormat("%s signal parameters: action=%s, price=%f, sl=%f, tp=%f", 
               symbol, action, price, sl, tp);

   // Process the signal
   ProcessSignal(action, symbol, price, sl, tp);
}

void ProcessSignal(const string action, const string symbol, const double price, const double sl, const double tp)
{
   PrintFormat("Processing signal: action=%s, symbol=%s, price=%f, sl=%f, tp=%f", action, symbol, price, sl, tp);
   
   // Check if symbol is in our allowed list
   if(!IsSymbolAllowed(symbol))
   {
      PrintFormat("Symbol %s not in allowed list, skipping", symbol);
      return;
   }
   
   ulong ticket = 0;
   int ptype = GetOurPosition(symbol, ticket);

   if(StringCompare(action, "close", false) == 0)
   {
     if(ptype != -1)
     {
        PrintFormat("Closing existing %s position on %s", (ptype == POSITION_TYPE_BUY) ? "BUY" : "SELL", symbol);
        ClosePosition(ticket, symbol);
     }
     else
        PrintFormat("No position to close for %s", symbol);
     return;
   }

   if(StringCompare(action, "update_sl", false) == 0)
   {
     if(ptype != -1 && sl > 0.0)
     {
        PrintFormat("Updating SL to %f for %s position", sl, symbol);
        UpdateSLTP(ticket, symbol, sl, 0.0, true);
     }
     else
        PrintFormat("Cannot update SL for %s: no position or invalid SL value", symbol);
     return;
   }

   if(StringCompare(action, "update_tp", false) == 0)
   {
     if(ptype != -1 && tp > 0.0)
     {
        PrintFormat("Updating TP to %f for %s position", tp, symbol);
        UpdateSLTP(ticket, symbol, 0.0, tp, false);
     }
     else
        PrintFormat("Cannot update TP for %s: no position or invalid TP value", symbol);
     return;
   }

   bool is_buy = (StringCompare(action, "buy", false) == 0);
   bool is_sell = (StringCompare(action, "sell", false) == 0);
   if(!is_buy && !is_sell)
   {
      PrintFormat("Unknown action for %s: %s", symbol, action);
      return;
   }

   // Validate market data
   double ask, bid;
   if(!SymbolInfoDouble(symbol, SYMBOL_ASK, ask) || !SymbolInfoDouble(symbol, SYMBOL_BID, bid))
   {
      PrintFormat("Cannot get market prices for %s", symbol);
      return;
   }
   
   // SL validation
   if(sl > 0.0)
   {
      if(is_buy && sl >= ask)
      {
         PrintFormat("Invalid BUY SL for %s: %f >= Ask %f", symbol, sl, ask);
         return;
      }
      if(is_sell && sl <= bid)
      {
         PrintFormat("Invalid SELL SL for %s: %f <= Bid %f", symbol, sl, bid);
         return;
      }
   }

   // If position exists
   if(ptype != -1)
   {
      // Same direction -> update SL/TP if provided
      if((is_buy && ptype == POSITION_TYPE_BUY) || (is_sell && ptype == POSITION_TYPE_SELL))
      {
         PrintFormat("Same direction signal received for %s, updating existing position", symbol);
         if(sl > 0.0 || tp > 0.0)
            UpdateSLTP(ticket, symbol, sl, tp, true);
         return;
      }
      // Opposite signal -> close and reopen
      PrintFormat("Opposite direction signal for %s, closing existing position", symbol);
      ClosePosition(ticket, symbol);
      // fallthrough to open new
   }

   // Opening a new position requires SL for risk sizing
   if(sl <= 0.0)
   {
      PrintFormat("No valid SL provided for %s %s signal; skipping open", symbol, action);
      return;
   }

   double lots = CalculateRiskBasedLots(symbol, sl, is_buy);
   if(lots <= 0.0)
   {
      PrintFormat("Calculated lots <= 0.0 for %s; skipping open", symbol);
      return;
   }

   // Additional safety checks
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margin_required = 0.0;
   if(!OrderCalcMargin(is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, symbol, lots, 
                       is_buy ? ask : bid, margin_required))
   {
      PrintFormat("Cannot calculate margin requirement for %s", symbol);
      return;
   }
   
   if(margin_required > free_margin * 0.8) // Don't use more than 80% of free margin per trade
   {
      PrintFormat("Insufficient margin for %s: required=%f, available=%f", symbol, margin_required, free_margin);
      return;
   }

   bool sent = false;
   if(is_buy)
      sent = trade.Buy(lots, symbol, 0.0, sl, tp);
   else
      sent = trade.Sell(lots, symbol, 0.0, sl, tp);

   if(!sent)
   {
      PrintFormat("Order send failed for %s: %d (%s)", symbol, GetLastError(), ErrorDescription(GetLastError()));
   }
   else
   {
      PrintFormat("Successfully opened %s %.2f lots on %s with SL=%f TP=%f", 
                  is_buy?"BUY":"SELL", lots, symbol, sl, tp);
   }
}

bool IsSymbolAllowed(const string symbol)
{
   for(int i = 0; i < g_symbol_count; i++)
   {
      if(StringCompare(g_allowed_symbols[i], symbol, false) == 0)
         return true;
   }
   return false;
}

void ParseAllowedSymbols()
{
   string symbols = AllowedSymbols;
   ArrayResize(g_allowed_symbols, 0);
   g_symbol_count = 0;
   
   while(StringLen(symbols) > 0)
   {
      int pos = StringFind(symbols, ",");
      string symbol;
      
      if(pos >= 0)
      {
         symbol = StringSubstr(symbols, 0, pos);
         symbols = StringSubstr(symbols, pos + 1);
      }
      else
      {
         symbol = symbols;
         symbols = "";
      }
      
      // Trim whitespace
      symbol = StringTrimLeft(symbol);
      symbol = StringTrimRight(symbol);
      
      if(StringLen(symbol) > 0)
      {
         ArrayResize(g_allowed_symbols, g_symbol_count + 1);
         g_allowed_symbols[g_symbol_count] = symbol;
         g_symbol_count++;
      }
   }
   
   PrintFormat("Parsed %d allowed symbols", g_symbol_count);
}

string StringTrimLeft(const string str)
{
   int start = 0;
   while(start < StringLen(str) && (StringGetCharacter(str, start) == ' ' || StringGetCharacter(str, start) == '\t'))
      start++;
   return StringSubstr(str, start);
}

string StringTrimRight(const string str)
{
   int end = StringLen(str) - 1;
   while(end >= 0 && (StringGetCharacter(str, end) == ' ' || StringGetCharacter(str, end) == '\t'))
      end--;
   return StringSubstr(str, 0, end + 1);
}

int GetOurPosition(const string symbol, ulong &ticket)
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(!position.SelectByIndex(i))
         continue;
      string sym = position.Symbol();
      if(sym != symbol)
         continue;
      long magic = position.Magic();
      if(ManageOnlyOurPositions && magic != MagicNumber)
         continue;
      ticket = position.Ticket();
      int type = (int)position.PositionType();
      return type; // POSITION_TYPE_BUY or POSITION_TYPE_SELL
   }
   return -1;
}

bool ClosePosition(const ulong ticket, const string symbol)
{
   bool ok = trade.PositionClose(ticket, MaxSlippagePoints);
   if(!ok)
      PrintFormat("PositionClose failed for %s: %d (%s)", symbol, GetLastError(), ErrorDescription(GetLastError()));
   else
      PrintFormat("Closed position on %s", symbol);
   return ok;
}

bool UpdateSLTP(const ulong ticket, const string symbol, double new_sl, double new_tp, bool allow_partial)
{
   // Retrieve current SL/TP
   if(!position.Select(symbol))
      return false;
   double cur_sl = position.StopLoss();
   double cur_tp = position.TakeProfit();

   // Apply partial updates
   if(allow_partial)
   {
      if(new_sl <= 0.0) new_sl = cur_sl;
      if(new_tp <= 0.0) new_tp = cur_tp;
   }

   bool ok = trade.PositionModify(ticket, new_sl, new_tp);
   if(!ok)
      PrintFormat("PositionModify failed for %s: %d (%s)", symbol, GetLastError(), ErrorDescription(GetLastError()));
   else
      PrintFormat("Modified position on %s: SL=%f TP=%f", symbol, new_sl, new_tp);
   return ok;
}

bool CheckDailyLossLimit()
{
   datetime current_time = TimeCurrent();
   datetime current_day = current_time - (current_time % 86400);
   datetime last_reset_day = g_last_balance_reset - (g_last_balance_reset % 86400);
   
   if(current_day > last_reset_day)
   {
      g_daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_last_balance_reset = current_time;
      Print("New trading day started. Balance reset to: ", g_daily_start_balance);
      return true;
   }
   
   double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double daily_loss_pct = ((g_daily_start_balance - current_balance) / g_daily_start_balance) * 100.0;
   
   if(daily_loss_pct > MaxDailyLoss)
   {
      PrintFormat("Daily loss limit exceeded: %.2f%% (limit: %.2f%%)", daily_loss_pct, MaxDailyLoss);
      return false;
   }
   
   return true;
}

double CalculateRiskBasedLots(const string symbol, const double sl, const bool is_buy)
{
   double ask, bid;
   if(!SymbolInfoDouble(symbol, SYMBOL_ASK, ask) || !SymbolInfoDouble(symbol, SYMBOL_BID, bid))
      return 0.0;

   double entry = is_buy ? ask : bid;
   double distance = MathAbs(entry - sl);
   if(distance <= 0.0)
      return 0.0;

   double tick_size, tick_value;
   if(!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE, tick_size) || 
      !SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE, tick_value))
      return 0.0;
   if(tick_size <= 0.0)
      return 0.0;

   double value_per_price_unit_per_lot = tick_value / tick_size;
   double risk_per_lot = distance * value_per_price_unit_per_lot;
   if(risk_per_lot <= 0.0)
      return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double effective_risk_pct = MathMin(RiskPercent, MaxRiskPercent);
   double risk_amount = balance * (effective_risk_pct/100.0);
   if(risk_amount <= 0.0)
      return 0.0;

   double raw_lots = risk_amount / risk_per_lot;

   double vol_min, vol_max, vol_step;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN, vol_min))
      vol_min = 0.01;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX, vol_max))
      vol_max = 100.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP, vol_step))
      vol_step = 0.01;
      
   if(vol_step <= 0.0)
      vol_step = 0.01;

   double lots = MathFloor(raw_lots/vol_step) * vol_step;
   if(lots < vol_min) lots = vol_min;
   if(lots > vol_max) lots = vol_max;
   lots = NormalizeDouble(lots, 2);
   
   PrintFormat("Risk calc for %s: Entry=%f, SL=%f, Distance=%f, Risk/lot=%f, Final lots=%f", 
               symbol, entry, sl, distance, risk_per_lot, lots);
   
   return lots;
}

void ApplyBreakevenAndTrailingAll()
{
   // Apply to all our positions
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(!position.SelectByIndex(i))
         continue;
      
      long magic = position.Magic();
      if(ManageOnlyOurPositions && magic != MagicNumber)
         continue;
         
      string symbol = position.Symbol();
      if(!IsSymbolAllowed(symbol))
         continue;
         
      ApplyBreakevenAndTrailing(symbol);
   }
}

void ApplyBreakevenAndTrailing(const string symbol)
{
   if(!position.Select(symbol))
      return;

   long magic = position.Magic();
   if(ManageOnlyOurPositions && magic != MagicNumber)
      return;

   int type = (int)position.PositionType();
   double price_open = position.PriceOpen();
   double sl = position.StopLoss();
   double tp = position.TakeProfit();

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double bid, ask;
   bool bid_ok = SymbolInfoDouble(symbol, SYMBOL_BID, bid);
   bool ask_ok = SymbolInfoDouble(symbol, SYMBOL_ASK, ask);
   
   if(!bid_ok || !ask_ok || point <= 0.0)
      return;

   double cur = (type == POSITION_TYPE_BUY) ? bid : ask;
   double profit_points = (type == POSITION_TYPE_BUY) ? (cur - price_open)/point : (price_open - cur)/point;

   ulong ticket = position.Ticket();

   // Breakeven
   if(EnableBreakeven && profit_points >= BreakevenTriggerPoints)
   {
      double be_sl = (type == POSITION_TYPE_BUY) ? (price_open + BreakevenOffsetPoints*point)
                                                 : (price_open - BreakevenOffsetPoints*point);
      if(type == POSITION_TYPE_BUY) {
         if(sl <= 0.0 || be_sl > sl + 0.1*point)
            trade.PositionModify(ticket, be_sl, tp);
      } else {
         if(sl <= 0.0 || be_sl < sl - 0.1*point)
            trade.PositionModify(ticket, be_sl, tp);
      }
   }

   // Trailing
   if(EnableTrailingStop && profit_points >= TrailStartPoints)
   {
      double trail_sl = (type == POSITION_TYPE_BUY) ? (cur - TrailStepPoints*point)
                                                    : (cur + TrailStepPoints*point);
      if(type == POSITION_TYPE_BUY) {
         if(trail_sl > sl + 0.1*point)
            trade.PositionModify(ticket, trail_sl, tp);
      } else {
         if(sl <= 0.0 || trail_sl < sl - 0.1*point)
            trade.PositionModify(ticket, trail_sl, tp);
      }
   }
}

string ReadSignalJson()
{
   Print("Attempting to open multi-currency signal file: ", SignalFileName);
   int handle = FileOpen(SignalFileName, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_COMMON);
   
   if(handle == INVALID_HANDLE && CommonFilesDir != "")
   {
      string path = PathCombine(CommonFilesDir, SignalFileName);
      Print("Primary file not found, trying alternative path: ", path);
      handle = FileOpen(path, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   }
   
   if(handle == INVALID_HANDLE)
   {
      Print("Failed to open signal file. Error: ", GetLastError());
      return "";
   }

   int sz = (int)FileSize(handle);
   PrintFormat("Signal file opened successfully. Size: %d bytes", sz);
   
   if(sz == 0)
   {
      Print("Signal file is empty");
      FileClose(handle);
      return "";
   }
   
   string data = FileReadString(handle, sz);
   FileClose(handle);
   
   PrintFormat("Signal file read successfully. Content length: %d characters", StringLen(data));
   
   data.TrimLeft();
   data.TrimRight();
   
   if(StringLen(data) > 0 && StringGetCharacter(data, 0) == 65279)
   {
      data = StringSubstr(data, 1);
      Print("Removed BOM from signal file content");
   }
   
   PrintFormat("Cleaned content: %s", data);
   
   if(StringLen(data) < 2 || StringGetCharacter(data, 0) != '{' || 
      StringGetCharacter(data, StringLen(data)-1) != '}')
   {
      Print("Signal file content does not appear to be valid JSON");
      Print("Content: ", data);
      return "";
   }
   
   return data;
}

string PathCombine(const string a, const string b)
{
   if(a=="") return b;
   string sep = (StringGetCharacter(a, StringLen(a)-1) == '\\') ? "" : "\\";
   return a + sep + b;
}

bool ExtractString(const string json, const string key, string &out)
{
   string pat = "\"" + key + "\"" + ":";
   int pos = StringFind(json, pat);
   if(pos < 0) return false;
   pos += StringLen(pat);
   while(pos < (int)StringLen(json) && (StringGetCharacter(json, pos)==' ' || StringGetCharacter(json, pos)=='\t')) pos++;
   if(pos >= (int)StringLen(json) || StringGetCharacter(json, pos) != '"') return false;
   pos++;
   int start = pos;
   while(pos < (int)StringLen(json) && StringGetCharacter(json, pos) != '"') pos++;
   if(pos >= (int)StringLen(json)) return false;
   out = StringSubstr(json, start, pos-start);
   return true;
}

string ExtractSignalsObject(const string json)
{
   string pat = "\"signals\"" + ":";
   int pos = StringFind(json, pat);
   if(pos < 0) return "";
   pos += StringLen(pat);
   while(pos < (int)StringLen(json) && (StringGetCharacter(json, pos)==' ' || StringGetCharacter(json, pos)=='\t')) pos++;
   if(pos >= (int)StringLen(json) || StringGetCharacter(json, pos) != '{') return "";
   
   int start = pos;
   int bracket_count = 0;
   while(pos < (int)StringLen(json))
   {
      ushort ch = StringGetCharacter(json, pos);
      if(ch == '{') bracket_count++;
      else if(ch == '}') bracket_count--;
      pos++;
      if(bracket_count == 0) break;
   }
   
   return StringSubstr(json, start, pos - start);
}

string ExtractSymbolSignal(const string signals_json, const string symbol)
{
   string pat = "\"" + symbol + "\"" + ":";
   int pos = StringFind(signals_json, pat);
   if(pos < 0) return "";
   pos += StringLen(pat);
   while(pos < (int)StringLen(signals_json) && (StringGetCharacter(signals_json, pos)==' ' || StringGetCharacter(signals_json, pos)=='\t')) pos++;
   if(pos >= (int)StringLen(signals_json) || StringGetCharacter(signals_json, pos) != '{') return "";
   
   int start = pos;
   int bracket_count = 0;
   while(pos < (int)StringLen(signals_json))
   {
      ushort ch = StringGetCharacter(signals_json, pos);
      if(ch == '{') bracket_count++;
      else if(ch == '}') bracket_count--;
      pos++;
      if(bracket_count == 0) break;
   }
   
   return StringSubstr(signals_json, start, pos - start);
}

bool ExtractStringFromSignal(const string signal_json, const string key, string &out)
{
   return ExtractString(signal_json, key, out);
}

bool ExtractDoubleFromSignal(const string signal_json, const string key, double &out)
{
   string pat = "\"" + key + "\"" + ":";
   int pos = StringFind(signal_json, pat);
   if(pos < 0) return false;
   pos += StringLen(pat);
   while(pos < (int)StringLen(signal_json) && (StringGetCharacter(signal_json, pos)==' ' || StringGetCharacter(signal_json, pos)=='\t')) pos++;
   if(pos >= (int)StringLen(signal_json)) return false;

   if(StringSubstr(signal_json, pos, 4) == "null")
      return false;

   int start = pos;
   bool seen = false;
   while(pos < (int)StringLen(signal_json))
   {
      ushort ch = StringGetCharacter(signal_json, pos);
      if((ch>='0' && ch<='9') || ch=='.' || ch=='-' || ch=='+') { seen=true; pos++; continue; }
      break;
   }
   if(!seen) return false;
   string num = StringSubstr(signal_json, start, pos-start);
   out = StringToDouble(num);
   return true;
}

string ErrorDescription(int error_code)
{
   switch(error_code)
   {
      case 0:    return "No error";
      case 1:    return "No error, trade operation succeeded";
      case 2:    return "Common error";
      case 3:    return "Invalid trade parameters";
      case 4:    return "Trade server is busy";
      case 5:    return "Old version of the client terminal";
      case 6:    return "No connection with trade server";
      case 7:    return "Not enough rights";
      case 8:    return "Too frequent requests";
      case 9:    return "Malfunctional trade operation";
      case 64:   return "Account disabled";
      case 65:   return "Invalid account";
      case 128:  return "Trade timeout";
      case 129:  return "Invalid price";
      case 130:  return "Invalid stops";
      case 131:  return "Invalid trade volume";
      case 132:  return "Market is closed";
      case 133:  return "Trade is disabled";
      case 134:  return "Not enough money";
      case 135:  return "Price changed";
      case 136:  return "Off quotes";
      case 137:  return "Broker is busy";
      case 138:  return "Requote";
      case 139:  return "Order is locked";
      case 140:  return "Buy orders only allowed";
      case 141:  return "Too many requests";
      default:   return StringFormat("Unknown error %d", error_code);
   }
}
