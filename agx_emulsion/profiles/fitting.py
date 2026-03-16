import copy

import numpy as np
import scipy

from agx_emulsion.model.process import photo_params, photo_process


def fit_print_filters_iter(profile):
    p = copy.copy(profile)
    p.debug.deactivate_spatial_effects = True
    p.debug.deactivate_stochastic_effects = True
    p.print_paper.glare.compensation_removal_factor = 0.0
    p.io.input_cctf_decoding = False
    p.io.input_color_space = "sRGB"
    p.io.resize_factor = 1.0
    p.camera.auto_exposure = False
    p.enlarger.print_exposure_compensation = False
    midgray_rgb = np.array([[[0.184, 0.184, 0.184]]])
    c_filter = p.enlarger.c_filter_neutral

    def midgray_print(ymc_values, print_exposure):
        p.enlarger.y_filter_neutral = ymc_values[0]
        p.enlarger.m_filter_neutral = ymc_values[1]
        p.enlarger.print_exposure = print_exposure
        rgb = photo_process(midgray_rgb, p)
        return rgb

    def evaluate_residues(x):
        res = midgray_print([x[0], x[1], c_filter], x[2])
        res = res - midgray_rgb
        res = res.flatten()
        return res

    y_filter = p.enlarger.y_filter_neutral
    m_filter = p.enlarger.m_filter_neutral
    x0 = [y_filter, m_filter, 1.0]
    x = scipy.optimize.least_squares(
        evaluate_residues,
        x0,
        bounds=([0, 0, 0], [1, 1, 10]),
        ftol=1e-6,
        xtol=1e-6,
        gtol=1e-6,
        method="trf",
    )
    print("Total residues:", np.sum(np.abs(evaluate_residues(x.x))), "<-", evaluate_residues(x0))
    profile.enlarger.y_filter_neutral = x.x[0]
    profile.enlarger.m_filter_neutral = x.x[1]
    profile.enlarger.c_filter_neutral = c_filter
    return x.x[0], x.x[1], evaluate_residues(x.x)


def fit_print_filters(profile, iterations=10):
    print(profile.negative.info.stock)
    for i in range(iterations):
        filter_y, filter_m, residues = fit_print_filters_iter(profile)
        if np.sum(np.abs(residues)) < 1e-4 or i == iterations - 1:
            c_filter = profile.enlarger.c_filter_neutral
            print("Fitted Filters :" + f"[ {filter_y:.2f}, {filter_m:.2f}, {c_filter:.2f} ]")
            break

        profile.enlarger.y_filter_neutral = 0.5 * filter_y + np.random.uniform(0, 1) * 0.5
        profile.enlarger.m_filter_neutral = 0.5 * filter_m + np.random.uniform(0, 1) * 0.5
    return filter_y, filter_m, residues


def fit_all_stocks(iterations=5, randomess_starting_points=0.5):
    """Script helper retained for batch fitting from stock enums.

    This utility keeps the historical behavior but lives in profiles layer,
    where fitting logic now belongs.
    """
    from agx_emulsion.model.stocks import FilmStocks, Illuminants, PrintPapers

    ymc_filters_0 = {}
    residues = {}
    for paper in PrintPapers:
        ymc_filters_0[paper.value] = {}
        residues[paper.value] = {}
        for light in Illuminants:
            ymc_filters_0[paper.value][light.value] = {}
            residues[paper.value][light.value] = {}
            for film in FilmStocks:
                ymc_filters_0[paper.value][light.value][film.value] = [0.90, 0.70, 0.35]
                residues[paper.value][light.value][film.value] = 0.184

    ymc_filters_out = copy.deepcopy(ymc_filters_0)
    r = randomess_starting_points

    for paper in PrintPapers:
        print(" " * 20)
        print("#" * 20)
        print(paper.value)
        for light in Illuminants:
            print("-" * 20)
            print(light.value)
            for stock in FilmStocks:
                if residues[paper.value][light.value][stock.value] > 5e-4:
                    y0 = ymc_filters_0[paper.value][light.value][stock.value][0]
                    m0 = ymc_filters_0[paper.value][light.value][stock.value][1]
                    c0 = ymc_filters_0[paper.value][light.value][stock.value][2]
                    y0 = np.clip(y0, 0, 1) * (1 - r) + np.random.uniform(0, 1) * r
                    m0 = np.clip(m0, 0, 1) * (1 - r) + np.random.uniform(0, 1) * r

                    p = photo_params(
                        negative=stock.value,
                        print_paper=paper.value,
                        ymc_filters_from_database=False,
                    )
                    p.enlarger.illuminant = light.value
                    p.enlarger.y_filter_neutral = y0
                    p.enlarger.m_filter_neutral = m0
                    p.enlarger.c_filter_neutral = c0

                    yf, mf, res = fit_print_filters(p, iterations=iterations)
                    ymc_filters_out[paper.value][light.value][stock.value] = [yf, mf, c0]
                    residues[paper.value][light.value][stock.value] = np.sum(np.abs(res))

    return ymc_filters_out, residues
