-- Inofficial Mollie Extension (www.Mollie.com) for MoneyMoney
-- Fetches Payments from Mollie API and returns them as transactions
--
-- Password: Mollie Secret API Key
--
-- Copyright (c) 2018 Nico Lindemann
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

WebBanking{version     = 1.0,
           url         = "https://api.mollie.com/",
           services    = {"Mollie Account"},
           description = "Fetches Payments from Mollie API and returns them as transactions"}

local apiSecret
local account
local apiUrlVersion = "v2"


local function iso8601ToUnix(isoStr) 
  local year, month, day, hour, min, sec = isoStr:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  local dt = os.date("*t", os.time({year = year, month = month, day = day, hour = hour, min = min, sec = sec}) + 2 * 60 * 60)
  --local dt = os.date( "*t", os.time() + 2 * 60 * 60 )
  return os.time(dt)
end

local function iso8601ToUnixCompensation(isoStr) 
  local year, month, day, hour, min, sec = isoStr:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  local dt = os.date("*t", os.time({year = year, month = month, day = day, hour = hour, min = min, sec = sec}) + -22 * 60 * 60)
  --local dt = os.date( "*t", os.time() + 2 * 60 * 60 )
  return os.time(dt)
end

function SupportsBank (protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Mollie Account"
end

function InitializeSession (protocol, bankCode, username, username2, password, username3)
  account = username
  apiSecret = password
end

function ListAccounts (knownAccounts)
  local account = {
    name = "Mollie Account",
    accountNumber = account,
    type = AccountTypeGiro
  }

  return {account}
end

function RefreshAccountOld(account, since)
  local availableBalance, availableCurrency, pendingBalance = GetAccountBalance()

  local balances = {
    { availableBalance, availableCurrency }
  }

  local transactions, totalAmount = GetPayments(since)
  print("Number of transactions: " .. #transactions)

  return {
    balance = availableBalance,
    balances = balances,
    pendingBalance = pendingBalance,
    transactions = transactions
  }
end

function RefreshAccount(account, since)
  local availableBalance, availableCurrency, pendingBalance, balanceId = GetAccountBalance()
  local balances = {
    { availableBalance, availableCurrency }
  } 

  local transactions = GetTransactionsByType(balanceId)

  return {
    balance = availableBalance,
    balances = balances,
    pendingBalance = pendingBalance,
    transactions = transactions
  }
end


function GetAccountBalance() 
  local balanceResponse = MollieRequest("balances"):dictionary()
  local balanceData = balanceResponse["_embedded"]["balances"][1]

  local availableBalance = tonumber(balanceData["availableAmount"]["value"])
  local availableCurrency = string.upper(balanceData["availableAmount"]["currency"])
  
  local pendingBalance = tonumber(balanceData["pendingAmount"]["value"])
  local balanceId = balanceData["id"]

  return availableBalance, availableCurrency, pendingBalance,balanceId
end

function GetTransactionsByType(balanceId)
  local endpoint = nil
  local transactions = {}
  local lastTransaction = nil
  local moreItemsAvailable = true
  repeat
    if lastTransaction == nil then
      endpoint = "balances/" .. balanceId .. "/transactions?limit=50"
    else
      endpoint = "balances/" .. balanceId .. "/transactions?limit=50&from=" .. lastTransaction
    end
    local transactionsResponse = MollieRequest(endpoint):dictionary()
    local transactionsData = transactionsResponse["_embedded"]["balance_transactions"]
    moreItemsAvailable = transactionsResponse["_links"] and transactionsResponse["_links"]["next"] ~= nil
        -- Extract the 'from' value from the 'next' link

    -- Check if 'from' value is found and assign it to 'lastTransaction'
    if moreItemsAvailable then
      lastTransaction = string.match(transactionsResponse["_links"]["next"]["href"], "from=([^&]+)") 
    else
      -- Handle the case where 'from' value is not found (e.g., set it to nil or a default value)
      lastTransaction = nil
    end

    for _, value in pairs(transactionsData) do 
      local purpose = ""
      local transactionType = value["type"]
      local name = ""
      local accountNumber = ""
      local endToEndReference = ""
      local amountValue = 0.00
      local createdAtTimestamp = ""
      local mandateReference = ""
    
        if transactionType == "outgoing-transfer" then 
          createdAtTimestamp = iso8601ToUnix(value["createdAt"])
          amountValue = tonumber(value["initialAmount"]["value"])
          purpose = "Payout"
        elseif transactionType == "invoice-compensation" then 
            createdAtTimestamp = iso8601ToUnixCompensation(value["createdAt"])
            amountValue = tonumber(value["initialAmount"]["value"])
            purpose = "Invoice-Compensation"
        elseif transactionType == "refund" then
          createdAtTimestamp = iso8601ToUnix(value["createdAt"])
          amountValue = tonumber(value["initialAmount"]["value"])
          --local refundData = MollieRequest("payments/" .. value["context"]["paymentId"] .. "/refunds/" .. value["context"]["refundId"]):dictionary()
          --purpose = refundData["description"] or ""
          local paymentData = MollieRequest("payments/" .. value["context"]["paymentId"]):dictionary()
          purpose = paymentData["description"] or ""
          name = paymentData["details"] and paymentData["details"]["consumerName"] or ""
          accountNumber = paymentData["details"] and paymentData["details"]["consumerAccount"] or ""
          endToEndReference = paymentData["metadata"] and paymentData["metadata"]["shopify_payment_id"] or ""
          -- if fees exists 
      
          if value["deductions"] and value["deductions"]["value"] then
            transactions[#transactions + 1] = {
              name = name,
              accountNumber = accountNumber,
              bookingDate = createdAtTimestamp,
              paidDate = createdAtTimestamp,
              purpose = "Fees - Refund",
              endToEndReference = endToEndReference,
              amount = (value["deductions"]["value"]),
              currency = string.upper(value["deductions"]["currency"])
            }
          end
        elseif transactionType == "payment" then
          amountValue = tonumber(value["initialAmount"]["value"])
          local paymentData = MollieRequest("payments/" .. value["context"]["paymentId"]):dictionary()
          purpose = paymentData["description"] or ""
          name = paymentData["details"] and paymentData["details"]["consumerName"] or ""
          accountNumber = paymentData["details"] and paymentData["details"]["consumerAccount"] or ""
          mandateReference = paymentData["method"] or ""
          endToEndReference = paymentData["metadata"] and paymentData["metadata"]["shopify_payment_id"] or ""
          createdAtTimestamp = iso8601ToUnix(paymentData["paidAt"])
          print (value["id"])
          print (name)
          print(value["createdAt"])
          print(value["createdAt"])

          -- if fees exists 
          if value["deductions"] and value["deductions"]["value"] then
            transactions[#transactions + 1] = {
              name = name,
              accountNumber = accountNumber,
              bookingDate = createdAtTimestamp,
              paidDate = createdAtTimestamp,
              purpose = "Fees",
              endToEndReference = endToEndReference,
              amount = (value["deductions"]["value"]),
              currency = string.upper(value["deductions"]["currency"])
            }
          end

        else
          createdAtTimestamp = iso8601ToUnix(value["createdAt"])
          amountValue = tonumber(value["initialAmount"]["value"])
          purpose = value["type"] or ""  
          endToEndReference = value["context"] and value["context"]["invoiceId"] or ""
        end
        print(value["createdAt"])

        transactions[#transactions + 1] = {
          name = name,
          accountNumber = accountNumber,
          mandateReference = mandateReference,
          bookingDate = createdAtTimestamp,
          paidDate = createdAtTimestamp,
          purpose = purpose,
          endToEndReference = endToEndReference,
          amount = amountValue,
          currency = string.upper(value["resultAmount"]["currency"])
        } 
    end
  until (not moreItemsAvailable)
  return transactions
end



function MollieRequest (endPoint)
  local headers = {}

  headers["Authorization"] = "Bearer " .. apiSecret
  headers["Accept"] = "application/json"

  connection = Connection()
  content = connection:request("GET", url .. apiUrlVersion .. "/" .. endPoint, nil, nil, headers)
  json = JSON(content)

  return json
end 


function GetPayments(since)
  local transactions = {}
  local lastTransaction = nil
  local moreItemsAvailable = true
  local requestString
  local sumAmount = 0

  repeat
      if lastTransaction == nil then
          requestString = "payments?limit=250"
      else
          requestString = "payments?limit=100&from=" .. lastTransaction
      end

      local MollieObject = MollieRequest(requestString):dictionary()
      moreItemsAvailable = MollieObject["_links"] and MollieObject["_links"]["next"] ~= nil

      for _, value in pairs(MollieObject["_embedded"]["payments"]) do 

          local createdAtTimestamp = iso8601ToUnix(value["createdAt"])
          local paidAtTimestamp = createdAtTimestamp 

          if value["status"] ~= "paid" then
            goto continue_loop
          end
 
          --if createdAtTimestamp <= since then
              -- if createdAt date is older or equal to the since date, skip this payment
              --goto continue_loop
          --end*/

          lastTransaction = value["id"]
          local purpose = value["description"]
          local amountValue = tonumber(value["amount"]["value"])

          -- If the refunded key exists, set amountValue to negative amountRefunded value
          if value["amountRefunded"] and tonumber(value["amountRefunded"]["value"]) ~= 0 then
            amountValue = -tonumber(value["amountRefunded"]["value"])
          end
        

          sumAmount = sumAmount + amountValue -- Add the current amount to the sum
        
          transactions[#transactions + 1] = {
              name = value["details"] and value["details"]["consumerName"] or "",
              accountNumber = value["details"] and value["details"]["consumerAccount"] or "",
              bookingDate = createdAtTimestamp,
              paidDate = paidAtTimestamp or "", -- retained from previous update
              purpose = purpose,
              endToEndReference = value["metadata"] and value["metadata"]["shopify_payment_id"] or "",
              amount = amountValue,
              currency = string.upper(value["amount"]["currency"])
          }
          
          ::continue_loop::
      end

  until (not moreItemsAvailable)

  return transactions, sumAmount -- Return both values
end



function EndSession ()
  -- Logout.
end 