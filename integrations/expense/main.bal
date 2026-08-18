// Expense approval: a human decides, then an activity posts the result.
//
// Importing the bridge is the whole integration story — no management port, no
// workflow-specific plumbing. Every replica of this container is another worker on the
// same Temporal task queue, so the ICP sees one integration with N runtimes.
import ballerina/workflow;
import wso2/icp.runtime.bridge as _;

type Expense record {|
    string id;
    decimal amount;
    string submittedBy;
|};

type Approval record {|
    boolean approved;
    string comment?;
|};

type LedgerEntry record {|
    string reference;
    decimal amount;
|};

# Approval of an expense: parks on a human task, then posts an approved expense.
@workflow:Workflow
function expenseApproval(workflow:Context ctx, Expense expense) returns LedgerEntry|error {
    Approval approval = check ctx->awaitHumanTask("approveExpense", "APPROVER",
        payload = {"id": expense.id, "amount": expense.amount, "submittedBy": expense.submittedBy},
        title = "Approve expense " + expense.id);
    if !approval.approved {
        return error("Expense rejected: " + (approval.comment ?: "no reason given"));
    }
    LedgerEntry entry = check ctx->callActivity(postToLedger,
        {"id": expense.id, "amount": expense.amount});
    return entry;
}

# No human step: for checking the definition list and a plain start-to-finish run.
@workflow:Workflow
function expenseAudit(workflow:Context ctx, string expenseId) returns string|error {
    LedgerEntry entry = check ctx->callActivity(postToLedger, {"id": expenseId, "amount": 0d});
    return entry.reference;
}

@workflow:Activity
function postToLedger(string id, decimal amount) returns LedgerEntry|error {
    return {reference: "LEDGER-" + id, amount: amount};
}
