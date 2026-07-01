# AWS Bedrock Setup for Redpanda ADP

Complete the AWS-side setup in this document **before** registering the LLM provider in ADP ([Step 1 of the main guide](./README.md#1-set-up-an-llm-provider-admin)). Follow it **exactly** — the IAM policy resources, the marketplace permissions, and the inference-profile requirement are load-bearing. Skipping or altering a step causes `AccessDenied` or invalid-model errors when you create or test the provider.

**Official reference:** [Set up Amazon Bedrock for ADP](https://docs.redpanda.com/agentic-data-plane/gateway/bedrock-setup/)

## Prerequisites

- An AWS account
- AWS CLI configured with IAM credentials that can create policies, users, and access keys
- Access to the Redpanda ADP UI

---

## Step 1: Enable model access

In the **AWS Bedrock console → Model access**, request access to each Claude model you plan to use, **in your target region** (e.g. `us-east-1`). Access must be granted per region — a model enabled in `us-east-1` is not available in `eu-west-1`.

> Bedrock serves current Claude models (4.6+) through **Marketplace model deployments**. Enabling model access may create a Marketplace subscription, which is why the IAM policy below includes `aws-marketplace:*` actions.

---

## Step 2: Create the IAM policy

The policy grants Bedrock invocation **and** the AWS Marketplace permissions required to use Bedrock Marketplace engines. Save the following as `redpanda-bedrock-policy.json`:

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

Create the policy:

```bash
aws iam create-policy \
  --policy-name RedpandaBedrockInvoke \
  --policy-document file://redpanda-bedrock-policy.json
```

Note the `Arn` in the output (`arn:aws:iam::<account-id>:policy/RedpandaBedrockInvoke`).

> **Why the Marketplace actions matter:** Claude 4.6+ models are provisioned as Bedrock Marketplace engines. Without `aws-marketplace:ViewSubscriptions` / `Subscribe` / `Unsubscribe`, the first invocation of a not-yet-subscribed model fails even though the `bedrock:*` permissions are correct.
>
> **Tightening the policy (optional):** to scope `bedrock:*` down from `"Resource": "*"`, restrict it to `arn:aws:bedrock:*::foundation-model/*` **and** `arn:aws:bedrock:*:*:inference-profile/*` — both are required, because Claude 4.6+ is invoked through inference profiles, not bare foundation-model IDs. The Marketplace statement must remain `"Resource": "*"`.

---

## Step 3: Create a dedicated IAM user and attach the policy

```bash
aws iam create-user --user-name redpanda-bedrock-invoker

aws iam attach-user-policy \
  --user-name redpanda-bedrock-invoker \
  --policy-arn arn:aws:iam::<account-id>:policy/RedpandaBedrockInvoke
```

Replace `<account-id>` with your AWS account ID from the Step 2 output.

---

## Step 4: Generate access keys

```bash
aws iam create-access-key --user-name redpanda-bedrock-invoker
```

**Store `AccessKeyId` and `SecretAccessKey` immediately — AWS displays the secret only once.** These are the values you paste into ADP as secret references.

---

## Step 5: (Optional) Verify access before registering

Confirm the IAM user can invoke Bedrock before configuring the provider:

```bash
aws bedrock-runtime invoke-model \
  --region us-east-1 \
  --model-id us.anthropic.claude-sonnet-4-6 \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}' \
  --cli-binary-format raw-in-base64-out \
  /dev/stdout
```

An `AccessDenied` here means the policy or Marketplace subscription is incomplete — fix it before moving on.

---

## Step 6: Register in Redpanda ADP

Now continue in the console — see [Step 1 of the main guide](./README.md#1-set-up-an-llm-provider-admin):

1. **LLM Providers → Create provider** → provider type **AWS Bedrock**.
2. Lowercase **Display name** (e.g. `bedrock-adp`).
3. **Region** matching where you enabled model access (e.g. `us-east-1`).
4. **Credential type: Static keys** → create secret references `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from Step 4.
5. Select models by **inference profile ID** (Claude 4.6+ requires a geographic prefix):
   - `global.anthropic.claude-opus-4-7` (any region, no cross-region premium — good default)
   - `us.anthropic.claude-sonnet-4-6` / `eu.anthropic.claude-sonnet-4-6`
   - `us.anthropic.claude-haiku-4-5` / `eu.anthropic.claude-haiku-4-5`
6. **Create provider** and test the connection.

---

## Notes & troubleshooting

- **Inference profiles are mandatory for Claude 4.6+.** Bare foundation-model IDs (e.g. `anthropic.claude-opus-4-8`) are rejected; use the `<geo>.anthropic.<model>` form. Only 4.5-and-earlier models accept bare IDs.
- **Cross-region premium:** `us.` / `eu.` / `apac.` inference profiles carry a ~10% cross-region premium. The `global.` prefix does not.
- **`AccessDenied` on first call** usually means the Marketplace subscription hasn't completed — confirm the model shows as granted under **Model access**, and that the IAM policy includes the `aws-marketplace:*` statement above.
- **Region mismatch:** the provider's region in ADP must be a region where you enabled the model.
