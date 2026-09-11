# A small door, not a new recommender

A post embedding is a list of 768 numbers produced by the existing frozen V1
model. Call it **x**. A logistic classifier learns one coefficient for each
number (**W**) and one overall offset (**b**). It has 769 learned scalars.
Neither campus names nor teacher explanations are additional input features.

## Forward calculation

```text
z = Wᵀx + b = W₁x₁ + … + W₇₆₈x₇₆₈ + b
q = sigmoid(z) = 1 / (1 + exp(-z))
```

`z` is an unrestricted score. `q` is a number between zero and one, interpreted
as estimated transferability probability. That interpretation is not a claim
of empirical calibration: a real holdout must test it.

For numeric stability, use `1/(1+exp(-z))` when z≥0 and
`exp(z)/(1+exp(z))` when z<0. This avoids computing `exp(1000)`. Reject non-finite
inputs rather than letting NaN accidentally pass a comparison.

## Learning from a label

`y=1` means transferable across schools. `y=0` means local. Binary
cross-entropy penalizes confident wrong answers:

```text
L = -[y log(q) + (1-y) log(1-q)]
y=1 → L=-log(q)
y=0 → L=-log(1-q)
J = (1/N) Σᵢ Lᵢ
```

Compute loss from logits as `logaddexp(0,z) - y*z` instead of directly taking
`log(0)` at extreme probabilities. The production embedding transformer is
never trained; only W and b change.

## Why the derivative is simple

```text
∂L/∂q = -y/q + (1-y)/(1-q)
∂q/∂z = q(1-q)
∂L/∂z = [-y/q + (1-y)/(1-q)] q(1-q) = q-y
∂z/∂W = x
∇W L = (q-y)x
∂L/∂b = q-y
```

If the probability is too high for a local example, q-y is positive: gradient
descent moves parameters toward a lower probability for that input. If it is
too low for a transferable example, the sign reverses.

```text
W ← W - η ∇W J
b ← b - η ∂J/∂b
∇W J_batch = (1/|B|) Σᵢ∈B (qᵢ-yᵢ)xᵢ
```

η is a learning rate. B is a minibatch. The implementation uses scikit-learn's
tested L-BFGS optimizer rather than hand-written gradient descent. The learned
model is still exactly the above logistic regression.

## Regularization and optional soft labels

The CLI's `--regularization` is **1/C**, not a replacement embedding or feature
scaler. With sample weights sᵢ, scikit-learn's L2 objective can be expressed as
`Σ sᵢLᵢ / Σsᵢ + ||W||²/(2C Σsᵢ)`; the intercept is unpenalized for L-BFGS.
Class weighting defaults to none. Optional `balanced` weights are computed
only from the training subset.

An optional teacher probability t substitutes for y in the BCE expression.
The code gives an input two weighted copies, y=0 with weight (1-t) and y=1
with weight t. This has exactly the soft-target BCE objective. Teacher reasoning
is neither embedded nor passed to the student. Hard labels plus confidence
filtering are the default.

## Eligibility, kept separate from ranking

```text
same known origin/viewer school → allow, even if classifier fails
different known schools → allow iff compatible, finite q ≥ τ
unknown origin/viewer or invalid foreign score → reject
```

τ is an independently versioned operating threshold chosen on validation data.
Equality passes. It does not change W/b. Once admitted, a post goes through
unchanged V1 S/E/F/Q/A/X ranking and the existing ignore penalty. Never add
`alpha*q` to the ranking equation.

Reference: [scikit-learn logistic regression](https://scikit-learn.org/stable/modules/linear_model.html#logistic-regression).
