# Distribution pricing comparison

Checked: 2026-11-05. Official public prices, no promotional discounts or purchases. Planning only.

## Cloudflare R2 Standard

Source: https://developers.cloudflare.com/r2/pricing/

- Storage: USD 0.015/GB-month after free allowance.
- Free monthly allowance: 10 GB-month storage, 1 million Class A operations and 10 million Class B operations. Shared account consumption matters.
- Class A: USD 4.50/million; Class B: USD 0.36/million, beyond allowance. Billing unit rounding applies.
- Direct Internet egress has no charge. Other connected metered services may charge separately.
- R2 custom domain delivery need not involve a paid Workers subscription. Existing domain cost is excluded. This does not include Cloudflare China Network.

## Tencent Cloud mainland CDN

Sources:

- CDN base pricing: https://cloud.tencent.com/document/product/228/2949
- HTTPS pricing: https://cloud.tencent.com/document/product/228/75563
- COS storage example: https://cloud.tencent.com/document/product/436/53482
- COS egress charging: https://cloud.tencent.com/document/product/436/53863

Mainland CDN first tier (0 to under 2 TB/month): CNY 0.21/GB. Higher tiers are progressive. Overseas rates differ.

HTTPS: 3 million requests/account/month free; above allowance CNY 0.05/10,000 requests. Optional QUIC/logging services have separate charges and are not required for basic downloads.

COS adds storage, read/write requests and CDN origin egress. The official Guangzhou example quotes Standard storage CNY 0.118/GB-month and requests CNY 0.01/10,000; the example is not a fresh checkout quote for all regions. COS CDN origin egress is explicitly billable; do not present the CDN table as a complete invoice. Resource packages may lower price; do not rely on promotional packages in the baseline.

## Workload estimate

Public 0.1.3 Release contains 43,019,984 bytes across its eight files, approximately 43 MB/version. Individual downloads are approximately 10–11 MB. Use a rounded 11 MB/download for comparison, decimal GB. Count installer downloads and updates as separate transfers, not unique users.

Assumptions: Standard R2 storage and operation totals remain within account free allowance; no paid Worker; one file transfer per download, no repeated failed transfers, metadata polling below request allowances. Retain fewer than 10 GB-month of versions. CDN calculations are traffic fee only.

| Completed downloads/month | Approximate traffic | R2 within allowance | Mainland CDN traffic only |
| --- | --- | --- | --- |
| 1,000 | 11 GB | USD 0 | CNY 2.31 |
| 10,000 | 110 GB | USD 0 | CNY 23.10 |
| 100,000 | 1,100 GB | USD 0 | CNY 231.00 |

These are estimates, not guaranteed caps. CDN protocol accounting, origin misses, retries, additional update checks, other account usage, billing units and actual checkout prices affect total. New domain registration and mainland CDN domain eligibility/filing are outside the transfer estimate.

## Decision still needed

R2 is lowest baseline cost and suitable for a first network test, but cannot promise improved mainland access. If stable mainland downloads are the priority, a domestic CDN's modest traffic cost can be justified. User has requested price research but has not yet selected audience/infrastructure or approved deployment.
