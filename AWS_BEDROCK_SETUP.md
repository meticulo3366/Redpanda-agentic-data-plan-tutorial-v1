# AWS Bedrock Setup for Redpanda ADP

This is the AWS-side groundwork you need to do **before** registering the Bedrock provider in ADP ([Step 1 of the main guide](./README.md#1-set-up-an-llm-provider-admin)). It's five short steps: turn on the models, create a permission policy, make a user, generate keys, and (optionally) test.

**Please follow it exactly.** A few details here are easy to skim past but genuinely load-bearing — the Marketplace permissions in the IAM policy and the inference-profile requirement in particular. Miss one and you'll get `AccessDenied` or "invalid model" errors later, and it won't be obvious why.

**Official reference:** [Set up Amazon Bedrock for ADP](https://docs.redpanda.com/agentic-data-plane/gateway/bedrock-setup/)

## What you'll need

- An AWS account.
- The AWS CLI, configured with credentials that can create policies, users, and access keys.
- Access to the Redpanda ADP UI.

---

## Step 1: Turn on model access

In the **AWS Bedrock console → Model access**, request access to each Claude model you plan to use — and do it **in the region you'll actually use** (say, `us-east-1`). Access is per-region: enabling a model in `us-east-1` does nothing for `eu-west-1`.

> Heads up: current Claude models (4.6+) are delivered as Bedrock **Marketplace** deployments. Turning on access can create a Marketplace subscription behind the scenes — which is exactly why the IAM policy in the next step includes `aws-marketplace:*` permissions.

---

## Step 2: Create the IAM policy

This policy does two things: it allows Bedrock inference, and it allows the AWS Marketplace actions that Bedrock's Marketplace engines depend on. Save it as `redpanda-bedrock-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowBedrockInference",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowBedrockMarketplaceModelAccess",
      "Effect": "Allow",
      "Action": [
        "aws-marketplace:ViewSubscriptions",
        "aws-marketplace:Subscribe",
        "aws-marketplace:Unsubscribe"
      ],
      "Resource": "*"
    }
  ]
}
```

Create it:

```bash
aws iam create-policy \
  --policy-name RedpandaBedrockInvoke \
  --policy-document file://redpanda-bedrock-policy.json
```

Note the `Arn` from the output (`arn:aws:iam::<account-id>:policy/RedpandaBedrockInvoke`) — you'll attach it in the next step.

> **Why the Marketplace permissions matter.** Claude 4.6+ models are provisioned as Bedrock Marketplace engines. Without `aws-marketplace:ViewSubscriptions` / `Subscribe` / `Unsubscribe`, the *first* call to a model you haven't subscribed to yet fails — even though your `bedrock:*` permissions are perfectly correct. This is a common and confusing trap.
>
> **Want to tighten it later?** You can scope the `bedrock:*` actions down from `"Resource": "*"` to `arn:aws:bedrock:*::foundation-model/*` **and** `arn:aws:bedrock:*:*:inference-profile/*` — you need both, since Claude 4.6+ is invoked through inference profiles, not plain foundation-model IDs. Leave the Marketplace statement as `"Resource": "*"`.

---

## Step 3: Create a user and attach the policy

Make a dedicated IAM user for the gateway and give it the policy:

```bash
aws iam create-user --user-name redpanda-bedrock-invoker

aws iam attach-user-policy \
  --user-name redpanda-bedrock-invoker \
  --policy-arn arn:aws:iam::<account-id>:policy/RedpandaBedrockInvoke
```

Swap in your AWS account ID (it's in the ARN from Step 2) for `<account-id>`.

---

## Step 4: Generate access keys

```bash
aws iam create-access-key --user-name redpanda-bedrock-invoker
```

**Copy `AccessKeyId` and `SecretAccessKey` right now — AWS shows the secret only once.** These are exactly the values you'll paste into ADP as secret references in Step 1 of the main guide.

---

## Step 5: (Optional) Test before you register

Worth doing — it tells you the AWS side is solid before you touch ADP:

```bash
aws bedrock-runtime invoke-model \
  --region us-east-1 \
  --model-id us.anthropic.claude-sonnet-4-6 \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}' \
  --cli-binary-format raw-in-base64-out \
  /dev/stdout
```

If this returns `AccessDenied`, the policy or the Marketplace subscription isn't complete yet — sort that out before moving on, or you'll just hit the same wall inside ADP.

---

## Step 6: Register the provider in ADP

You're done on the AWS side. Head back to the console and follow [Step 1 of the main guide](./README.md#1-set-up-an-llm-provider-admin). The short version:

1. **LLM Providers → Create provider**, provider type **AWS Bedrock**.
2. A lowercase **Display name** like `bedrock-adp`.
3. The **Region** where you enabled model access (e.g. `us-east-1`).
4. **Credential type: Static keys** → create secret references `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from Step 4.
5. Select models by **inference profile ID** (Claude 4.6+ needs a geographic prefix):
   - `global.anthropic.claude-opus-4-7` — any region, no cross-region premium. A good default.
   - `us.anthropic.claude-sonnet-4-6` / `eu.anthropic.claude-sonnet-4-6`
   - `us.anthropic.claude-haiku-4-5` / `eu.anthropic.claude-haiku-4-5`
6. **Create provider** and test the connection.

---

## Gotchas worth knowing

- **Inference profiles are required for Claude 4.6+.** Plain foundation-model IDs (like `anthropic.claude-opus-4-8`) get rejected — use the `<geo>.anthropic.<model>` form. Only 4.5-and-earlier models accept the plain IDs.
- **`global.` avoids the cross-region premium.** The `us.` / `eu.` / `apac.` profiles carry roughly a 10% cross-region premium; `global.` doesn't.
- **`AccessDenied` on the first call** usually means the Marketplace subscription hasn't finished. Check that the model shows as granted under **Model access**, and that your policy has the `aws-marketplace:*` statement.
- **Region has to match.** The region you set on the ADP provider must be one where you actually enabled the model.
