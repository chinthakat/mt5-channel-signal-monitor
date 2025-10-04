//+------------------------------------------------------------------+
//| ChannelSignalMonitor.mq5                                         |
//|                                                                  |
//| Single-symbol Expert Advisor. Watches the MetaTrader 5 shared    |
//| Common\Files folder for signal files named                       |
//| <channelName>_<chart symbol>_*.json, written there by an         |
//| external producer that is not part of this project.              |
//|                                                                  |
//| For each file it has not already seen this session it parses     |
//| the signal, discards it unless its time_utc is within            |
//| signalWindowMinutes of the broker's clock, then opens a market   |
//| order (event_type "entry") or closes this EA's positions on the  |
//| symbol (event_type "exit" or "close"). Stop loss and take        |
//| profit are taken from the signal and clamped against the         |
//| broker's stop level and the minSLPoints/maxSLPoints inputs; lot  |
//| size comes from riskPercentage of balance over the SL distance.  |
//|                                                                  |
//| Every event is appended as a row to                              |
//| <channelName>_<symbol>_monitor_log.csv in Common\Files.          |
//|                                                                  |
//| See README.md for the input reference and the JSON schema.       |
//+------------------------------------------------------------------+
#property copyright "Channel Signal Monitor EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

// Input parameters
input string channelName = "My_Channel"; // Channel name to monitor
input int signalWindowMinutes = 5; // Time window for signal validity (minutes)
input double riskPercentage = 1.0; // Risk percentage per trade
input double defaultLotSize = 0.01; // Default lot size if risk calculation fails
input int slippagePoints = 10; // Maximum slippage in points
input double minSLPoints = 100; // Minimum SL distance in points
input double maxSLPoints = 500; // Maximum SL distance in points
input int scanIntervalSeconds = 5; // Scan interval for new signals
input int fileMonitorIntervalSeconds = 60; // File monitoring interval when no files found
input bool enableLogging = true; // Enable detailed logging
input bool enableFileLogging = true; // Enable logging to file
input int brokerGMTOffset = 3; // Broker server GMT offset (e.g., 3 for GMT+3)
input bool assumeCurrentYearMonth = true; // Use current year/month if signal date seems wrong

// Global variables
CTrade trade;
CPositionInfo position;
string processedSignals[]; // Array to store processed signal filenames
datetime lastScanTime = 0;
datetime lastMonitorLogTime = 0;
string currentSymbol;
bool logFileReady = false;
int signalCounter = 0;
bool filesFoundPreviously = false;
string dynamicLogFileName; // Dynamic log file name

// Signal structure
struct SignalData
{
    string source;
    string symbol;
    string action;
    double price;
    double sl;
    double tp;
    datetime timeUtc;
    string fileName;
    string eventType;
    string orderType;
};

// Forward declarations
void InitializeLogFile();
void LogEvent(string eventType, string details, string status = "");
void LogSignal(const SignalData &signal, string action, string status, string reason = "");
void LogError(string context, int errorCode, string details);
string GetAccountStatus();
bool AppendToLogFile(string line);
string FormatLogField(string text);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    currentSymbol = Symbol();
    ArrayResize(processedSignals, 0);
    
    // Generate dynamic log file name with channel and symbol
    dynamicLogFileName = channelName + "_" + currentSymbol + "_monitor_log.csv";
    
    // Initialize log file
    InitializeLogFile();
    
    // Set trade parameters
    trade.SetExpertMagicNumber(20240827);
    trade.SetDeviationInPoints(slippagePoints);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    
    Print("=================================================");
    Print("Channel Signal Monitor EA Initialized");
    Print("Channel: ", channelName);
    Print("Symbol: ", currentSymbol);
    Print("Signal Window: ", signalWindowMinutes, " minutes");
    Print("Risk Per Trade: ", riskPercentage, "%");
    Print("Scan Interval: ", scanIntervalSeconds, " seconds");
    Print("Monitor Interval: ", fileMonitorIntervalSeconds, " seconds");
    Print("Broker Server Time: GMT", (brokerGMTOffset >= 0 ? "+" : ""), brokerGMTOffset);
    Print("Auto-fix future dates: ", assumeCurrentYearMonth);
    Print("Log File: ", dynamicLogFileName);
    Print("Current Broker Time: ", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
    
    // Calculate and display current UTC time
    datetime utcTime = TimeCurrent() - (brokerGMTOffset * 3600);
    Print("Current UTC Time: ", TimeToString(utcTime, TIME_DATE|TIME_SECONDS));
    Print("=================================================");
    
    // Log initialization with monitoring details
    string initDetails = StringFormat(
        "EA initialized on %s for channel %s. Scan every %d sec, Monitor log every %d sec, Broker GMT%s%d", 
        currentSymbol, channelName, scanIntervalSeconds, fileMonitorIntervalSeconds,
        (brokerGMTOffset >= 0 ? "+" : ""), brokerGMTOffset
    );
    LogEvent("INIT", initDetails, "SUCCESS");
    
    // Initial scan message
    Print("Starting continuous monitoring for signal files...");
    Print("Pattern: ", channelName, "_", currentSymbol, "_*.json");
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check if it's time to scan for new signals
    if(TimeCurrent() - lastScanTime < scanIntervalSeconds)
        return;
        
    lastScanTime = TimeCurrent();
    
    // Scan for new signal files
    ScanAndProcessSignals();
}

//+------------------------------------------------------------------+
//| Scan for new signal files and process them                      |
//+------------------------------------------------------------------+
void ScanAndProcessSignals()
{
    string searchPattern = channelName + "_" + currentSymbol + "_*.json";
    string fileName;
    long searchHandle = FileFindFirst(searchPattern, fileName, FILE_COMMON);
    
    if(searchHandle == INVALID_HANDLE)
    {
        // No files found - implement continuous monitoring
        datetime currentTime = TimeCurrent();
        
        // Log monitoring status at specified intervals
        if(currentTime - lastMonitorLogTime >= fileMonitorIntervalSeconds)
        {
            string monitorMsg = StringFormat("Monitoring for files: %s (checked every %d seconds)", 
                                           searchPattern, scanIntervalSeconds);
            
            // If files were found previously but now missing, log as warning
            if(filesFoundPreviously)
            {
                LogEvent("MONITOR", monitorMsg, "NO_FILES_WARNING");
                filesFoundPreviously = false;
                Print("Warning: Previously found signal files are now missing");
            }
            else
            {
                LogEvent("MONITOR", monitorMsg, "WAITING");
            }
            
            // Also print to terminal periodically
            if(enableLogging)
            {
                Print("Monitoring: No signal files found. Pattern: ", searchPattern);
                Print("Next check in ", scanIntervalSeconds, " seconds...");
            }
            
            lastMonitorLogTime = currentTime;
        }
        
        return;
    }
    
    // Files found - process them
    filesFoundPreviously = true;
    int filesFound = 0;
    int filesProcessed = 0;
    int filesAlreadyProcessed = 0;
    
    do
    {
        filesFound++;
        // Check if this signal has already been processed
        if(!IsSignalProcessed(fileName))
        {
            filesProcessed++;
            ProcessSignalFile(fileName);
        }
        else
        {
            filesAlreadyProcessed++;
        }
    }
    while(FileFindNext(searchHandle, fileName));
    
    FileFindClose(searchHandle);
    
    // Log scan results
    if(filesProcessed > 0)
    {
        LogEvent("SCAN", 
                StringFormat("Found %d files: %d new, %d already processed", 
                           filesFound, filesProcessed, filesAlreadyProcessed), 
                "NEW_SIGNALS");
        
        if(enableLogging)
            Print("Processed ", filesProcessed, " new signal(s) from ", filesFound, " file(s)");
    }
    else if(filesFound > 0 && filesAlreadyProcessed > 0)
    {
        // Only log if enough time has passed to avoid spam
        static datetime lastProcessedLog = 0;
        if(TimeCurrent() - lastProcessedLog > 300) // Log every 5 minutes
        {
            LogEvent("SCAN", 
                    StringFormat("All %d files already processed", filesFound), 
                    "NO_NEW");
            lastProcessedLog = TimeCurrent();
        }
    }
}

//+------------------------------------------------------------------+
//| Check if signal has already been processed                      |
//+------------------------------------------------------------------+
bool IsSignalProcessed(string fileName)
{
    for(int i = 0; i < ArraySize(processedSignals); i++)
    {
        if(processedSignals[i] == fileName)
            return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Add signal to processed list                                    |
//+------------------------------------------------------------------+
void AddToProcessedSignals(string fileName)
{
    int size = ArraySize(processedSignals);
    ArrayResize(processedSignals, size + 1);
    processedSignals[size] = fileName;
    
    // Keep only last 100 processed signals to avoid memory issues
    if(size > 100)
    {
        ArrayRemove(processedSignals, 0, size - 100);
    }
}

//+------------------------------------------------------------------+
//| Process a signal file                                           |
//+------------------------------------------------------------------+
void ProcessSignalFile(string fileName)
{
    SignalData signal;
    signalCounter++;
    
    LogEvent("FILE_READ", StringFormat("Processing file: %s (Signal #%d)", fileName, signalCounter), "START");
    
    // Add timestamp to processing message
    Print("=================================================");
    Print("[", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), "] New signal detected!");
    Print("File: ", fileName);
    
    if(!LoadSignalFromFile(fileName, signal))
    {
        LogError("FILE_PARSE", GetLastError(), StringFormat("Failed to parse file: %s", fileName));
        AddToProcessedSignals(fileName); // Mark as processed to avoid retry
        return;
    }
    
    // Check if signal is within time window
    datetime currentTime = TimeCurrent();
    int timeDifferenceMinutes = (int)((currentTime - signal.timeUtc) / 60);
    
    // Debug time comparison
    if(enableLogging)
    {
        Print("Time Validation:");
        Print("  Broker Server Time: ", TimeToString(currentTime, TIME_DATE|TIME_SECONDS), " (GMT", 
              (brokerGMTOffset >= 0 ? "+" : ""), brokerGMTOffset, ")");
        Print("  Signal Time (adjusted): ", TimeToString(signal.timeUtc, TIME_DATE|TIME_SECONDS));
        Print("  Difference: ", timeDifferenceMinutes, " minutes");
        Print("  Allowed Window: +/-", signalWindowMinutes, " minutes");
        
        if(MathAbs(timeDifferenceMinutes) > signalWindowMinutes)
        {
            Print("  >> Signal EXPIRED - outside time window");
        }
        else
        {
            Print("  >> Signal VALID - within time window");
        }
    }
    
    if(MathAbs(timeDifferenceMinutes) > signalWindowMinutes)
    {
        LogSignal(signal, "IGNORED", "EXPIRED", 
                 StringFormat("Time difference: %d minutes (max: %d)", 
                 MathAbs(timeDifferenceMinutes), signalWindowMinutes));
        AddToProcessedSignals(fileName);
        return;
    }
    
    // Process the signal
    Print("=================================================");
    Print("Processing Signal: ", fileName);
    Print("Source: ", signal.source);
    Print("Action: ", signal.action);
    Print("Price: ", signal.price);
    Print("SL: ", signal.sl);
    Print("TP: ", signal.tp);
    Print("Signal Time: ", TimeToString(signal.timeUtc, TIME_DATE|TIME_SECONDS));
    Print("Current Time: ", TimeToString(currentTime, TIME_DATE|TIME_SECONDS));
    Print("Time Difference: ", timeDifferenceMinutes, " minutes");
    
    // Execute trade based on signal
    if(signal.eventType == "entry")
    {
        ExecuteTrade(signal);
    }
    else if(signal.eventType == "exit" || signal.eventType == "close")
    {
        ClosePositions(signal);
    }
    else
    {
        LogSignal(signal, "IGNORED", "UNKNOWN_TYPE", 
                 StringFormat("Unknown event type: %s", signal.eventType));
    }
    
    AddToProcessedSignals(fileName);
    Print("=================================================");
}

//+------------------------------------------------------------------+
//| Load signal data from JSON file                                 |
//+------------------------------------------------------------------+
bool LoadSignalFromFile(string fileName, SignalData &signal)
{
    int handle = FileOpen(fileName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
    if(handle == INVALID_HANDLE)
    {
        int error = GetLastError();
        LogError("FILE_OPEN", error, StringFormat("Cannot open file: %s", fileName));
        Print("Failed to open file: ", fileName, " Error: ", error);
        return false;
    }
    
    string content = "";
    while(!FileIsEnding(handle))
    {
        content += FileReadString(handle);
    }
    FileClose(handle);
    
    // Parse JSON content
    signal.fileName = fileName;
    signal.source = ExtractJSONValue(content, "source");
    signal.symbol = ExtractJSONValue(content, "symbol");
    signal.action = ExtractJSONValue(content, "action");
    
    // Parse price, SL, TP with validation logging
    string priceStr = ExtractJSONValue(content, "price");
    string slStr = ExtractJSONValue(content, "sl");
    string tpStr = ExtractJSONValue(content, "tp");
    
    signal.price = StringToDouble(priceStr);
    signal.sl = StringToDouble(slStr);
    signal.tp = StringToDouble(tpStr);
    
    // Log extraction results
    if(enableLogging)
    {
        Print("JSON Field Extraction:");
        Print("  price: '", priceStr, "' -> ", signal.price);
        Print("  sl: '", slStr, "' -> ", signal.sl);
        Print("  tp: '", tpStr, "' -> ", signal.tp);
    }
    
    // Validate SL/TP extraction
    if(signal.sl == 0 && StringLen(slStr) > 0)
    {
        LogError("SL_PARSE", 0, StringFormat("Failed to parse SL: '%s' in file: %s", slStr, fileName));
    }
    if(signal.tp == 0 && StringLen(tpStr) > 0)
    {
        LogError("TP_PARSE", 0, StringFormat("Failed to parse TP: '%s' in file: %s", tpStr, fileName));
    }
    
    signal.eventType = ExtractJSONValue(content, "event_type");
    signal.orderType = ExtractJSONValue(content, "order_type");
    
    // Parse time
    string timeStr = ExtractJSONValue(content, "time_utc");
    signal.timeUtc = ParseISO8601Time(timeStr);
    
    // Validate parsed data
    if(signal.symbol != currentSymbol)
    {
        LogError("SYMBOL_MISMATCH", 0, 
                StringFormat("Expected: %s, Got: %s in file: %s", 
                currentSymbol, signal.symbol, fileName));
        Print("Symbol mismatch. Expected: ", currentSymbol, " Got: ", signal.symbol);
        return false;
    }
    
    if(StringLen(signal.action) == 0)
    {
        LogError("INVALID_ACTION", 0, StringFormat("Empty action in file: %s", fileName));
        Print("Invalid action in signal");
        return false;
    }
    
    LogSignal(signal, "LOADED", "SUCCESS", "Signal parsed successfully");
    return true;
}

//+------------------------------------------------------------------+
//| Extract value from JSON string                                  |
//+------------------------------------------------------------------+
string ExtractJSONValue(string json, string key)
{
    // Handle nested JSON structure
    string searchKey = "\"" + key + "\":";
    int startPos = StringFind(json, searchKey);
    if(startPos < 0)
    {
        // Try to find in nested signal object
        searchKey = "\"signal\"";
        int signalPos = StringFind(json, searchKey);
        if(signalPos >= 0)
        {
            searchKey = "\"" + key + "\":";
            startPos = StringFind(json, searchKey, signalPos);
        }
    }
    
    if(startPos < 0) return "";
    
    startPos += StringLen(searchKey);
    
    // Skip whitespace
    while(startPos < StringLen(json) && 
          (StringGetCharacter(json, startPos) == ' ' || 
           StringGetCharacter(json, startPos) == '\n' || 
           StringGetCharacter(json, startPos) == '\r'))
        startPos++;
    
    // Check if value is string (starts with quote)
    bool isString = (StringGetCharacter(json, startPos) == '"');
    if(isString) startPos++;
    
    int endPos = startPos;
    if(isString)
    {
        endPos = StringFind(json, "\"", startPos);
    }
    else
    {
        while(endPos < StringLen(json) && 
              StringGetCharacter(json, endPos) != ',' && 
              StringGetCharacter(json, endPos) != '}' && 
              StringGetCharacter(json, endPos) != '\n')
            endPos++;
    }
    
    if(endPos < 0) endPos = StringLen(json);
    
    return StringSubstr(json, startPos, endPos - startPos);
}

//+------------------------------------------------------------------+
//| Parse ISO-8601 formatted time string                            |
//+------------------------------------------------------------------+
datetime ParseISO8601Time(string timeStr)
{
    // Remove whitespace
    StringTrimLeft(timeStr);
    StringTrimRight(timeStr);
    
    if(StringLen(timeStr) == 0)
        return 0;
    
    // Store original for debugging
    string originalTimeStr = timeStr;
    
    // Replace T with space for MT5 format
    StringReplace(timeStr, "T", " ");
    
    // Handle timezone offset
    int tzOffsetHours = 0;
    int tzOffsetMinutes = 0;
    bool hasTimezone = false;
    
    // Check for Z (UTC)
    if(StringFind(timeStr, "Z") > 0)
    {
        StringReplace(timeStr, "Z", "");
        hasTimezone = true;
        tzOffsetHours = 0;
        tzOffsetMinutes = 0;
    }
    else
    {
        // Check for + or - timezone
        int plusPos = StringFind(timeStr, "+");
        int minusPos = StringFind(timeStr, "-", 10); // Skip date part
        
        int tzPos = -1;
        int tzSign = 1;
        
        if(plusPos > 10)
        {
            tzPos = plusPos;
            tzSign = 1;
        }
        else if(minusPos > 10)
        {
            tzPos = minusPos;
            tzSign = -1;
        }
        
        if(tzPos > 0)
        {
            hasTimezone = true;
            string tzPart = StringSubstr(timeStr, tzPos + 1);
            timeStr = StringSubstr(timeStr, 0, tzPos);
            
            // Remove colons from timezone
            StringReplace(tzPart, ":", "");
            
            // Parse timezone offset
            if(StringLen(tzPart) >= 2)
            {
                tzOffsetHours = (int)StringToInteger(StringSubstr(tzPart, 0, 2)) * tzSign;
                if(StringLen(tzPart) >= 4)
                    tzOffsetMinutes = (int)StringToInteger(StringSubstr(tzPart, 2, 2)) * tzSign;
            }
        }
    }
    
    // Trim any remaining whitespace
    StringTrimRight(timeStr);
    
    // Replace - with . for MT5 date format
    string datePart = "";
    string timePart = "";
    
    int spacePos = StringFind(timeStr, " ");
    if(spacePos > 0)
    {
        datePart = StringSubstr(timeStr, 0, spacePos);
        timePart = StringSubstr(timeStr, spacePos);
    }
    else
    {
        datePart = timeStr;
    }
    
    StringReplace(datePart, "-", ".");
    
    // Parse the datetime
    datetime baseTime = StringToTime(datePart + timePart);
    
    // Check if parsed time is valid
    if(baseTime == 0)
    {
        LogError("TIME_PARSE", 0, StringFormat("Failed to parse time: %s", originalTimeStr));
        return 0;
    }
    
    // Check if date seems to be in the future and fix it if needed
    if(assumeCurrentYearMonth)
    {
        datetime currentTime = TimeCurrent();
        
        // If signal time is more than 1 day in the future, it might have wrong year/month
        if(baseTime > currentTime + 86400)
        {
            // Extract time components
            MqlDateTime signalDt, currentDt;
            TimeToStruct(baseTime, signalDt);
            TimeToStruct(currentTime, currentDt);
            
            // Use current year and month, keep day and time from signal
            signalDt.year = currentDt.year;
            signalDt.mon = currentDt.mon;
            
            // If day is still in future, go to previous month
            if(signalDt.day > currentDt.day)
            {
                signalDt.mon = currentDt.mon - 1;
                if(signalDt.mon < 1)
                {
                    signalDt.mon = 12;
                    signalDt.year = currentDt.year - 1;
                }
            }
            
            baseTime = StructToTime(signalDt);
            
            if(enableLogging)
            {
                Print("Date adjusted from future. Original: ", originalTimeStr, 
                      " Adjusted to: ", TimeToString(baseTime, TIME_DATE|TIME_SECONDS));
            }
        }
    }
    
    // Convert to UTC first (if timezone was specified in signal)
    if(hasTimezone)
    {
        int offsetSeconds = (tzOffsetHours * 3600) + (tzOffsetMinutes * 60);
        baseTime = baseTime - offsetSeconds; // Convert to UTC
    }
    
    // Now convert from UTC to broker server time
    // If broker is GMT+3, we add 3 hours to UTC time
    datetime brokerTime = baseTime + (brokerGMTOffset * 3600);
    
    if(enableLogging)
    {
        Print("Time parsing details:");
        Print("  Original: ", originalTimeStr);
        Print("  Parsed local: ", TimeToString(baseTime, TIME_DATE|TIME_SECONDS));
        Print("  Signal TZ offset: GMT", (tzOffsetHours >= 0 ? "+" : ""), tzOffsetHours, ":", 
              (tzOffsetMinutes < 10 ? "0" : ""), tzOffsetMinutes);
        Print("  UTC time: ", TimeToString(baseTime - tzOffsetHours * 3600 - tzOffsetMinutes * 60, TIME_DATE|TIME_SECONDS));
        Print("  Broker time (GMT", (brokerGMTOffset >= 0 ? "+" : ""), brokerGMTOffset, "): ", 
              TimeToString(brokerTime, TIME_DATE|TIME_SECONDS));
    }
    
    return brokerTime;
}

//+------------------------------------------------------------------+
//| Execute trade based on signal                                   |
//+------------------------------------------------------------------+
void ExecuteTrade(const SignalData &signal)
{
    double bid = SymbolInfoDouble(currentSymbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(currentSymbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(currentSymbol, SYMBOL_POINT);
    
    string action = signal.action;
    StringToLower(action);
    
    bool isBuy = (StringFind(action, "buy") >= 0);
    bool isSell = (StringFind(action, "sell") >= 0);
    
    if(!isBuy && !isSell)
    {
        LogSignal(signal, "TRADE_FAILED", "INVALID_ACTION", 
                 StringFormat("Unrecognized action: %s", signal.action));
        Print("Invalid action: ", signal.action);
        return;
    }
    
    // Use market price for execution
    double entryPrice = isBuy ? ask : bid;
    
    // Store original SL/TP from signal
    double originalSL = signal.sl;
    double originalTP = signal.tp;
    
    // Validate and adjust SL/TP
    double sl = signal.sl;
    double tp = signal.tp;
    
    Print("Original Signal Values:");
    Print("  Entry Price (signal): ", signal.price);
    Print("  SL (signal): ", originalSL, " (", NormalizeDouble(MathAbs(signal.price - originalSL) / point, 0), " points from signal price)");
    Print("  TP (signal): ", originalTP, " (", NormalizeDouble(MathAbs(originalTP - signal.price) / point, 0), " points from signal price)");
    Print("  Current Entry Price: ", entryPrice);
    
    if(!ValidateAndAdjustLevels(isBuy, entryPrice, sl, tp, originalSL, originalTP))
    {
        LogSignal(signal, "TRADE_FAILED", "INVALID_LEVELS", 
                 "Failed to validate SL/TP levels");
        Print("Failed to validate SL/TP levels");
        return;
    }
    
    // Check if SL/TP were adjusted
    bool slAdjusted = (MathAbs(sl - originalSL) > point);
    bool tpAdjusted = (MathAbs(tp - originalTP) > point);
    
    if(slAdjusted || tpAdjusted)
    {
        string adjustmentMsg = "Levels adjusted: ";
        if(slAdjusted)
            adjustmentMsg += StringFormat("SL %.5f->%.5f ", originalSL, sl);
        if(tpAdjusted)
            adjustmentMsg += StringFormat("TP %.5f->%.5f ", originalTP, tp);
        
        LogEvent("LEVEL_ADJUSTMENT", adjustmentMsg, "ADJUSTED");
        Print(">>> ", adjustmentMsg);
    }
    
    // Calculate lot size
    double lotSize = CalculateLotSize(entryPrice, sl);
    
    Print("Executing ", isBuy ? "BUY" : "SELL", " order");
    Print("Entry: ", entryPrice);
    Print("SL: ", sl, " (", NormalizeDouble(MathAbs(entryPrice - sl) / point, 0), " points)");
    Print("TP: ", tp, " (", NormalizeDouble(MathAbs(tp - entryPrice) / point, 0), " points)");
    Print("Lot Size: ", lotSize);
    
    // Log pre-trade status
    string preTradeDetails = StringFormat(
        "Type:%s Entry:%.5f SL:%.5f(orig:%.5f) TP:%.5f(orig:%.5f) Lots:%.2f Bid:%.5f Ask:%.5f %s",
        isBuy ? "BUY" : "SELL", entryPrice, sl, originalSL, tp, originalTP, lotSize, bid, ask, GetAccountStatus()
    );
    LogEvent("PRE_TRADE", preTradeDetails, "EXECUTING");
    
    // Execute trade
    bool result = false;
    if(isBuy)
    {
        result = trade.Buy(lotSize, currentSymbol, entryPrice, sl, tp, 
                          "Signal: " + signal.source);
    }
    else
    {
        result = trade.Sell(lotSize, currentSymbol, entryPrice, sl, tp, 
                           "Signal: " + signal.source);
    }
    
    if(result)
    {
        string tradeDetails = StringFormat(
            "Order:%d Deal:%d Vol:%.2f Price:%.5f %s",
            trade.ResultOrder(), trade.ResultDeal(), 
            trade.ResultVolume(), trade.ResultPrice(), GetAccountStatus()
        );
        LogSignal(signal, "TRADE_SUCCESS", "EXECUTED", tradeDetails);
        
        Print("✓ Trade executed successfully");
        Print("Order: ", trade.ResultOrder());
        Print("Deal: ", trade.ResultDeal());
    }
    else
    {
        int error = GetLastError();
        string errorDetails = StringFormat(
            "Error:%d Retcode:%d Comment:%s %s",
            error, trade.ResultRetcode(), trade.ResultComment(), GetAccountStatus()
        );
        LogSignal(signal, "TRADE_FAILED", "ERROR", errorDetails);
        
        Print("✗ Failed to execute trade");
        Print("Error: ", error);
        Print("Result: ", trade.ResultRetcode());
    }
}

//+------------------------------------------------------------------+
//| Validate and adjust SL/TP levels                                |
//+------------------------------------------------------------------+
bool ValidateAndAdjustLevels(bool isBuy, double entryPrice, double &sl, double &tp, double originalSL, double originalTP)
{
    double point = SymbolInfoDouble(currentSymbol, SYMBOL_POINT);
    double stopLevel = SymbolInfoInteger(currentSymbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
    
    if(stopLevel == 0)
        stopLevel = 10 * point; // Default minimum distance
    
    Print("Validating Levels:");
    Print("  Stop Level Required: ", stopLevel / point, " points");
    Print("  Min SL Distance: ", minSLPoints, " points");
    Print("  Max SL Distance: ", maxSLPoints, " points");
    
    // Check if SL is set
    if(sl == 0)
    {
        Print("WARNING: No SL provided in signal");
        LogEvent("SL_VALIDATION", "No SL in signal, using default", "WARNING");
        if(isBuy)
            sl = entryPrice - minSLPoints * point;
        else
            sl = entryPrice + minSLPoints * point;
    }
    
    // Calculate SL distance from entry
    double slDistance = MathAbs(entryPrice - sl);
    double slPoints = slDistance / point;
    
    Print("  SL Distance from entry: ", slPoints, " points");
    
    // Check if SL respects stop level (broker requirement)
    if(slDistance < stopLevel)
    {
        Print("  SL too close to entry (broker stop level violation)");
        if(isBuy)
            sl = entryPrice - stopLevel - point;
        else
            sl = entryPrice + stopLevel + point;
            
        Print("  SL adjusted for broker stop level: ", sl);
        LogEvent("SL_VALIDATION", 
                StringFormat("SL adjusted for stop level: %.5f -> %.5f", originalSL, sl), 
                "ADJUSTED");
    }
    // Only apply min/max SL distance if it doesn't conflict with signal
    else if(slPoints < minSLPoints)
    {
        // Signal SL is tighter than our minimum - log warning but use signal value if it respects stop level
        Print("  WARNING: Signal SL (", slPoints, " points) is tighter than minSLPoints (", minSLPoints, ")");
        Print("  Using signal SL as it respects broker stop level");
        LogEvent("SL_VALIDATION", 
                StringFormat("Signal SL (%.1f points) tighter than min (%.0f points) - using signal value", 
                slPoints, minSLPoints), 
                "INFO");
    }
    else if(slPoints > maxSLPoints)
    {
        Print("  WARNING: Signal SL exceeds maxSLPoints, adjusting");
        if(isBuy)
            sl = entryPrice - maxSLPoints * point;
        else
            sl = entryPrice + maxSLPoints * point;
            
        Print("  SL adjusted to maximum distance: ", maxSLPoints, " points -> ", sl);
        LogEvent("SL_VALIDATION", 
                StringFormat("SL adjusted to max: %.5f -> %.5f (%.0f points)", originalSL, sl, maxSLPoints), 
                "ADJUSTED");
    }
    
    // Validate TP
    if(tp != 0)
    {
        double tpDistance = MathAbs(entryPrice - tp);
        Print("  TP Distance from entry: ", tpDistance / point, " points");
        
        if(tpDistance < stopLevel)
        {
            Print("  TP too close to entry (broker stop level violation)");
            if(isBuy)
                tp = entryPrice + stopLevel + point;
            else
                tp = entryPrice - stopLevel - point;
                
            Print("  TP adjusted for stop level: ", tp);
            LogEvent("TP_VALIDATION", 
                    StringFormat("TP adjusted for stop level: %.5f -> %.5f", originalTP, tp), 
                    "ADJUSTED");
        }
    }
    else
    {
        Print("  INFO: No TP provided in signal");
        LogEvent("TP_VALIDATION", "No TP in signal", "INFO");
    }
    
    // Normalize prices
    int digits = (int)SymbolInfoInteger(currentSymbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);
    
    Print("Final Levels:");
    Print("  SL: ", sl, " (", NormalizeDouble(MathAbs(entryPrice - sl) / point, 0), " points)");
    Print("  TP: ", tp, " (", NormalizeDouble(MathAbs(tp - entryPrice) / point, 0), " points)");
    
    return true;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk management                     |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, double stopLoss)
{
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = accountBalance * (riskPercentage / 100.0);
    
    double tickValue = SymbolInfoDouble(currentSymbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(currentSymbol, SYMBOL_TRADE_TICK_SIZE);
    double point = SymbolInfoDouble(currentSymbol, SYMBOL_POINT);
    
    double slPoints = MathAbs(entryPrice - stopLoss) / point;
    
    if(tickValue <= 0 || slPoints <= 0)
        return defaultLotSize;
    
    double lotSize = (riskAmount * tickSize) / (slPoints * point * tickValue);
    
    // Normalize lot size
    double minLot = SymbolInfoDouble(currentSymbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(currentSymbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(currentSymbol, SYMBOL_VOLUME_STEP);
    
    lotSize = MathMax(minLot, lotSize);
    lotSize = MathMin(maxLot, lotSize);
    lotSize = MathRound(lotSize / lotStep) * lotStep;
    
    return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Close positions based on signal                                 |
//+------------------------------------------------------------------+
void ClosePositions(const SignalData &signal)
{
    Print("Processing close signal");
    
    int totalPositions = PositionsTotal();
    int closedCount = 0;
    int failedCount = 0;
    double totalProfit = 0;
    
    string preCloseStatus = GetAccountStatus();
    LogSignal(signal, "CLOSE_START", "PROCESSING", 
             StringFormat("Attempting to close positions. %s", preCloseStatus));
    
    for(int i = totalPositions - 1; i >= 0; i--)
    {
        if(position.SelectByIndex(i))
        {
            if(position.Symbol() == currentSymbol && 
               position.Magic() == 20240827)
            {
                ulong ticket = position.Ticket();
                double profit = position.Profit();
                double volume = position.Volume();
                
                if(trade.PositionClose(ticket))
                {
                    closedCount++;
                    totalProfit += profit;
                    LogEvent("POSITION_CLOSE", 
                            StringFormat("Closed #%d Vol:%.2f Profit:%.2f", 
                            ticket, volume, profit), "SUCCESS");
                    Print("✓ Closed position #", ticket);
                }
                else
                {
                    failedCount++;
                    int error = GetLastError();
                    LogError("POSITION_CLOSE", error, 
                            StringFormat("Failed to close #%d", ticket));
                    Print("✗ Failed to close position #", ticket);
                }
            }
        }
    }
    
    string closeResult = StringFormat(
        "Closed:%d Failed:%d TotalProfit:%.2f %s",
        closedCount, failedCount, totalProfit, GetAccountStatus()
    );
    LogSignal(signal, "CLOSE_COMPLETE", 
             closedCount > 0 ? "SUCCESS" : "NO_POSITIONS", closeResult);
    
    if(closedCount > 0)
        Print("Total positions closed: ", closedCount);
    else
        Print("No positions to close");
}

//+------------------------------------------------------------------+
//| Initialize log file                                             |
//+------------------------------------------------------------------+
void InitializeLogFile()
{
    if(!enableFileLogging)
        return;
    
    // Try to open existing file first
    int handle = FileOpen(dynamicLogFileName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
    if(handle != INVALID_HANDLE)
    {
        logFileReady = true;
        FileClose(handle);
        Print("Using existing log file: ", dynamicLogFileName);
        return;
    }
    
    // Create new file with headers
    handle = FileOpen(dynamicLogFileName, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
    if(handle == INVALID_HANDLE)
    {
        Print("Failed to create log file: ", dynamicLogFileName, " Error: ", GetLastError());
        return;
    }
    
    string headers = "timestamp,signal_id,event_type,symbol,action,signal_price,signal_sl,signal_tp,";
    headers += "signal_time,file_name,status,reason,bid,ask,balance,equity,free_margin,open_positions,details";
    
    FileWriteString(handle, headers + "\n");
    FileClose(handle);
    logFileReady = true;
    Print("Created new log file: ", dynamicLogFileName);
}

//+------------------------------------------------------------------+
//| Log event to file                                               |
//+------------------------------------------------------------------+
void LogEvent(string eventType, string details, string status)
{
    if(!enableFileLogging || !logFileReady)
        return;
    
    double bid = SymbolInfoDouble(currentSymbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(currentSymbol, SYMBOL_ASK);
    
    string line = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
    line += ",-"; // signal_id
    line += "," + FormatLogField(eventType);
    line += "," + currentSymbol;
    line += ",-"; // action
    line += ",-"; // signal_price
    line += ",-"; // signal_sl
    line += ",-"; // signal_tp
    line += ",-"; // signal_time
    line += ",-"; // file_name
    line += "," + FormatLogField(status);
    line += ",-"; // reason
    line += "," + DoubleToString(bid, 5);
    line += "," + DoubleToString(ask, 5);
    line += "," + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2);
    line += "," + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2);
    line += "," + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2);
    line += "," + IntegerToString(PositionsTotal());
    line += "," + FormatLogField(details);
    
    AppendToLogFile(line);
}

//+------------------------------------------------------------------+
//| Log signal details to file                                      |
//+------------------------------------------------------------------+
void LogSignal(const SignalData &signal, string action, string status, string reason)
{
    if(!enableFileLogging || !logFileReady)
        return;
    
    double bid = SymbolInfoDouble(currentSymbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(currentSymbol, SYMBOL_ASK);
    
    string line = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
    line += "," + IntegerToString(signalCounter);
    line += "," + FormatLogField(signal.eventType);
    line += "," + signal.symbol;
    line += "," + FormatLogField(signal.action);
    line += "," + DoubleToString(signal.price, 5);
    line += "," + DoubleToString(signal.sl, 5);
    line += "," + DoubleToString(signal.tp, 5);
    line += "," + TimeToString(signal.timeUtc, TIME_DATE|TIME_SECONDS);
    line += "," + FormatLogField(signal.fileName);
    line += "," + FormatLogField(status);
    line += "," + FormatLogField(reason);
    line += "," + DoubleToString(bid, 5);
    line += "," + DoubleToString(ask, 5);
    line += "," + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2);
    line += "," + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2);
    line += "," + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2);
    line += "," + IntegerToString(PositionsTotal());
    line += "," + FormatLogField(signal.source);
    
    AppendToLogFile(line);
}

//+------------------------------------------------------------------+
//| Log error to file                                               |
//+------------------------------------------------------------------+
void LogError(string context, int errorCode, string details)
{
    if(!enableFileLogging || !logFileReady)
        return;
    
    string errorMsg = StringFormat("ERROR[%d] Context:%s Details:%s", 
                                  errorCode, context, details);
    LogEvent("ERROR", errorMsg, "FAILED");
}

//+------------------------------------------------------------------+
//| Get current account status                                      |
//+------------------------------------------------------------------+
string GetAccountStatus()
{
    return StringFormat("Balance:%.2f Equity:%.2f Margin:%.2f Positions:%d",
                       AccountInfoDouble(ACCOUNT_BALANCE),
                       AccountInfoDouble(ACCOUNT_EQUITY),
                       AccountInfoDouble(ACCOUNT_MARGIN_FREE),
                       PositionsTotal());
}

//+------------------------------------------------------------------+
//| Append line to log file                                         |
//+------------------------------------------------------------------+
bool AppendToLogFile(string line)
{
    if(!enableFileLogging || !logFileReady)
        return false;
    
    int handle = FileOpen(dynamicLogFileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
    if(handle == INVALID_HANDLE)
    {
        logFileReady = false;
        Print("Failed to open log file: ", dynamicLogFileName, " Error: ", GetLastError());
        return false;
    }
    
    FileSeek(handle, 0, SEEK_END);
    FileWriteString(handle, line + "\n");
    FileClose(handle);
    return true;
}

//+------------------------------------------------------------------+
//| Format field for CSV output                                     |
//+------------------------------------------------------------------+
string FormatLogField(string text)
{
    string result = text;
    StringReplace(result, ",", ";");
    StringReplace(result, "\"", "'");
    StringReplace(result, "\n", " ");
    StringReplace(result, "\r", " ");
    return result;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // Log final statistics
    string finalStats = StringFormat(
        "EA stopped. Total signals processed: %d, Files in memory: %d", 
        signalCounter, ArraySize(processedSignals)
    );
    LogEvent("DEINIT", finalStats, "STOPPED");
    
    ArrayFree(processedSignals);
    Print("Channel Signal Monitor EA deinitialized. Reason: ", reason);
}
