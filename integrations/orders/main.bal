// Order fulfilment: a second integration, deliberately unlike the first.
//
// Where the expense workflows park on a human task, these exercise the parts of the
// management surface that human tasks do not: an event-driven wait (so suspend, resume,
// wake and terminate act on an instance that is genuinely running), a review activity
// raised by a failing activity, and a child workflow. Two integrations in one environment
// also make target selection observable — each has its own runtimes and its own task
// queue, and a command must reach the right ones.
import ballerina/workflow;
import wso2/icp.runtime.bridge as _;

type Order record {|
    string orderId;
    string sku;
    int quantity;
|};

type Shipment record {|
    string orderId;
    string carrier;
    string tracking;
|};

type StockCheck record {|
    boolean inStock;
    int available;
|};

# Waits for a `paymentReceived` event, then ships. Parks on the event rather than a timer:
# an instance waiting on an event stays RUNNING until something signals it, which is what
# the lifecycle operations need to act on.
@workflow:Workflow
function orderFulfilment(workflow:Context ctx, Order 'order,
        record {|future<json> paymentReceived;|} events) returns Shipment|error {
    json payment = check wait events.paymentReceived;

    StockCheck stock = check ctx->callActivity(checkStock,
        {"sku": 'order.sku, "quantity": 'order.quantity});
    if !stock.inStock {
        return error(string `Out of stock: ${'order.sku} (${stock.available} available)`);
    }

    Shipment shipment = check ctx->callActivity(bookCarrier,
        {"orderId": 'order.orderId, "reference": payment.toJsonString()});
    return shipment;
}

# Fails on purpose the first time to raise a review activity, so reviewActivities.list /
# get / decide have something real to act on. `HumanReview` names the role that may decide.
@workflow:Workflow
function orderReconciliation(workflow:Context ctx, string orderId) returns string|error {
    string ledger = check ctx->callActivity(reconcileLedger, {"orderId": orderId},
        retryPolicy = "OPS");
    return ledger;
}

# Starts orderFulfilment as a child, so instance views show a parent with children.
@workflow:Workflow
function bulkOrderIntake(workflow:Context ctx, Order[] orders) returns string[]|error {
    string[] started = [];
    foreach Order 'order in orders {
        string childId = check ctx->runChildWorkflow(orderFulfilment, 'order);
        started.push(childId);
    }
    return started;
}

@workflow:Activity
function checkStock(string sku, int quantity) returns StockCheck|error {
    // Deterministic, so a test can predict the outcome: only SKU-OOS is out of stock.
    boolean inStock = sku != "SKU-OOS";
    return {inStock: inStock, available: inStock ? quantity + 10 : 0};
}

@workflow:Activity
function bookCarrier(string orderId, string reference) returns Shipment|error {
    return {orderId: orderId, carrier: "ACME", tracking: "TRK-" + orderId};
}

@workflow:Activity
function reconcileLedger(string orderId) returns string|error {
    // Always fails: the point is the review activity this raises, which a human then
    // retries or fails from the ICP console.
    return error(string `Ledger unavailable for ${orderId}`);
}
