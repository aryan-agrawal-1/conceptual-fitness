from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy import optimize, stats


MAX_PHI = 0.95


@dataclass(frozen=True)
class Fit:
    estimates: tuple[float, ...]
    standard_errors: tuple[float, ...]
    intervals: tuple[tuple[float, float], ...]
    p_value: float
    phi: float
    residual_sd: float
    observations: int
    degrees_of_freedom: int


class FitUnavailable(ValueError):
    pass


def whiten(values: np.ndarray, gaps: np.ndarray, phi: float) -> tuple[np.ndarray, np.ndarray]:
    decay = phi ** gaps[1:]
    scale = np.sqrt(1 - decay ** 2)
    shaped = values.reshape(len(values), -1)
    first = shaped[:1]
    rest = (shaped[1:] - decay[:, None] * shaped[:-1]) / scale[:, None]
    return np.vstack([first, rest]).reshape(values.shape), scale


def profile_log_likelihood(phi: float, y: np.ndarray, x: np.ndarray, gaps: np.ndarray) -> float:
    y_star, scale = whiten(y, gaps, phi)
    x_star, _ = whiten(x, gaps, phi)
    beta, *_ = np.linalg.lstsq(x_star, y_star, rcond=None)
    residuals = y_star - x_star @ beta
    sigma2 = float(residuals @ residuals) / len(y)
    if sigma2 <= 0:
        return np.inf
    return 0.5 * len(y) * np.log(sigma2) + float(np.sum(np.log(scale)))


def gls_ar1(y, x, days, tested: tuple[int, ...]) -> Fit:
    y = np.asarray(y, dtype=float)
    x = np.asarray(x, dtype=float)
    days = np.asarray(days, dtype=int)
    order = np.argsort(days)
    y, x, days = y[order], x[order], days[order]
    gaps = np.concatenate([[0], np.diff(days)])
    if np.any(gaps[1:] <= 0):
        raise FitUnavailable("duplicate_days")
    degrees = len(y) - x.shape[1]
    if degrees < 3 or np.linalg.matrix_rank(x) < x.shape[1]:
        raise FitUnavailable("insufficient_variation")
    found = optimize.minimize_scalar(
        profile_log_likelihood, bounds=(0.0, MAX_PHI), args=(y, x, gaps), method="bounded",
    )
    phi = float(found.x) if found.success else 0.0
    y_star, _ = whiten(y, gaps, phi)
    x_star, _ = whiten(x, gaps, phi)
    return least_squares(y_star, x_star, tested, phi=phi)


def ols(y, x, tested: tuple[int, ...]) -> Fit:
    y = np.asarray(y, dtype=float)
    x = np.asarray(x, dtype=float)
    if len(y) - x.shape[1] < 3 or np.linalg.matrix_rank(x) < x.shape[1]:
        raise FitUnavailable("insufficient_variation")
    return least_squares(y, x, tested, phi=0.0)


def least_squares(y: np.ndarray, x: np.ndarray, tested: tuple[int, ...], *, phi: float) -> Fit:
    degrees = len(y) - x.shape[1]
    beta, *_ = np.linalg.lstsq(x, y, rcond=None)
    residuals = y - x @ beta
    sigma2 = float(residuals @ residuals) / degrees
    covariance = sigma2 * np.linalg.inv(x.T @ x)
    index = list(tested)
    estimates = beta[index]
    errors = np.sqrt(np.diag(covariance)[index])
    critical = stats.t.ppf(0.975, degrees)
    sub = covariance[np.ix_(index, index)]
    wald = float(estimates @ np.linalg.solve(sub, estimates)) / len(index)
    p_value = float(stats.f.sf(wald, len(index), degrees))
    return Fit(
        estimates=tuple(float(item) for item in estimates),
        standard_errors=tuple(float(item) for item in errors),
        intervals=tuple((float(est - critical * err), float(est + critical * err))
                        for est, err in zip(estimates, errors)),
        p_value=p_value, phi=phi, residual_sd=float(np.sqrt(sigma2)),
        observations=len(y), degrees_of_freedom=degrees,
    )


def benjamini_hochberg(p_values: list[float]) -> list[float]:
    count = len(p_values)
    if not count:
        return []
    order = sorted(range(count), key=lambda index: p_values[index])
    adjusted = [0.0] * count
    running = 1.0
    for rank in range(count, 0, -1):
        index = order[rank - 1]
        running = min(running, p_values[index] * count / rank)
        adjusted[index] = running
    return adjusted


def shrink(estimate: float, standard_error: float, prior_sd: float) -> float:
    if prior_sd <= 0:
        return 0.0
    return estimate * prior_sd ** 2 / (prior_sd ** 2 + standard_error ** 2)
