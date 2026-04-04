import matplotlib.pyplot as plt
from spektrafilm_profile_creator.factory import create_profile, process_negative_profile, process_paper_profile, replace_fitted_density_curves, adjust_log_exposure
from spektrafilm_profile_creator.plotting import plot_profile
from spektrafilm.profiles.io import save_profile
from spektrafilm_profile_creator.correct import correct_negative_curves_with_gray_ramp, align_midscale_neutral_exposures

process_print_paper = True
process_negative = True

print('----------------------------------------')
print('Paper profiles')
#               label,                               name,                               ref_illu        illu    sens, curv, dye,  dom
paper_info = [('kodak_ektacolor_edge',              'Kodak Ektacolor Edge',              'TH-KG3-L',  'D50',  None, None, None, 1.0),
              ('kodak_ultra_endura',                'Kodak Professional Ultra Endura',   'TH-KG3-L',  'D50',  None, None, None, 1.0),
              ('kodak_endura_premier',              'Kodak Professional Endura Premier', 'TH-KG3-L',  'D50',  None, None, None, 1.0),
              ('kodak_portra_endura',               'Kodak Professional Portra Endura',  'TH-KG3-L',  'D50',  None, None, None, 1.0),
              ('kodak_supra_endura',                'Kodak Professional Supra Endura',   'TH-KG3-L',  'D50',  'kodak_portra_endura', None, 'kodak_portra_endura', 1.0),
              ('fujifilm_crystal_archive_typeii',   'Fujifilm Crystal Archive Type II',  'TH-KG3-L',  'D50',  None, 'kodak_supra_endura', None, 1.0),
              ('kodak_2393',                        'Kodak Vision Premier 2393',         'TH-KG3-L',  'K75P', None, None, None, 1.0),
              ('kodak_2383',                        'Kodak Vision 2383',                 'TH-KG3-L',  'K75P', None, None, None, 1.0),
]

if process_print_paper:
    for label, name, ref_illu, illu, sens, curv, dye, dom in paper_info:
        profile = create_profile(stock=label,
                                name=name,
                                profile_type='negative',
                                support='paper',
                                log_sensitivity_donor=sens,
                                denisty_curves_donor=curv,
                                dye_density_cmy_donor=dye,
                                densitometer='status_A',
                                reference_illuminant=ref_illu,
                                viewing_illuminant=illu,
                                log_sensitivity_density_over_min=dom)
        save_profile(profile)
        plot_profile(profile)
        profile = process_paper_profile(profile)
        save_profile(profile, '_uc')


print('----------------------------------------')
print('Negative profiles')

#               label,                    name,                       suffix   dye_donor,   ls_donor            ddmm_donor           d_over_min, ref_ill target_print,                align_mid_exp  trustability proc?
stock_info = [
              ('kodak_vision3_50d',      'Kodak Vision3 50D',         '',      None       , None,               None,                0.2,        'D55',  'kodak_2383_uc',             None,          0.3,         True),
              ('kodak_vision3_250d',     'Kodak Vision3 250D',        '',      None       , None,               None,                0.2,        'D55',  'kodak_2383_uc',             None,          0.3,         True),
              ('kodak_vision3_200t',     'Kodak Vision3 200T',        '',      None       , None,               None,                0.2,        'T',    'kodak_2383_uc',             None,          0.3,         True),
              ('kodak_vision3_500t',     'Kodak Vision3 500T',        '',      None       , None,               None,                0.2,        'T',    'kodak_2383_uc',             None,          0.3,         True),
              ('kodak_ektar_100',        'Kodak Ektar 100',           '',      'generic_a', None,               None,                0.2,        'D55',  'kodak_portra_endura_uc',    None,          1.0,         True),
              ('kodak_portra_160',       'Kodak Portra 160',          '',      'generic_a', None,               None,                0.2,        'D55',  'kodak_portra_endura_uc',    None,          1.0,         True),
              ('kodak_portra_400',       'Kodak Portra 400',          '',      'generic_a', None,               None,                0.2,        'D55',  'kodak_portra_endura_uc',    None,          1.0,         True),
              ('kodak_portra_800',       'Kodak Portra 800',          '',      'generic_a', None,               None,                0.2,        'D55',  'kodak_portra_endura_uc',    None,          1.0,         True),
              ('kodak_portra_800_push1', 'Kodak Portra 800 (Push 1)', '',      'generic_a', 'kodak_portra_800', 'kodak_portra_800',  0.2,        'D55',  'kodak_portra_endura_uc',    None,          1.0,         True),
              ('kodak_portra_800_push2', 'Kodak Portra 800 (Push 2)', '',      'generic_a', 'kodak_portra_800', 'kodak_portra_800',  0.2,        'D55',  'kodak_portra_endura_uc',    None,          1.0,         True),
              ('kodak_gold_200',         'Kodak Gold 200',            '',      'generic_a', None,               None,                0.2,        'D55',  'kodak_portra_endura_uc',    None,          1.0,         True),
              ('kodak_ultramax_400',     'Kodak Ultramax 400',        '',      'generic_a', None,               None,                0.2,        'D55',  'kodak_portra_endura_uc',    None,          1.0,         True),
              ('fujifilm_pro_400h',      'Fujifilm Pro 400H',         '',      'generic_a', None,               None,                1.0,        'D55',  'kodak_portra_endura_uc',    'mid',         0.3,         True),
              ('fujifilm_xtra_400',      'Fujifilm X-Tra 400',        '',      'generic_a', None,               None,                1.0,        'D55',  'kodak_portra_endura_uc',    None,          0.3,         True),
              ('fujifilm_c200',          'Fujifilm C200',             '',      'generic_a', None,               None,                1.0,        'D55',  'kodak_portra_endura_uc',    'green',       0.3,         True),
              ]

if process_negative:
    for label, name, suff, dye, ls_donor, ddmm_donor, d_over_min, ref_ill, target_print, align_mid_exp, trustability, proc in stock_info:
        if not proc:
            continue
        profile = create_profile(stock=label,
                                 name=name,
                                 profile_type='negative',
                                 densitometer='status_M',
                                 dye_density_cmy_donor=dye,
                                 log_sensitivity_donor=ls_donor,
                                 dye_density_min_mid_donor=ddmm_donor,
                                 reference_illuminant=ref_ill,
                                 log_sensitivity_density_over_min=d_over_min)
        save_profile(profile)
        suffix = '_'+suff
        if dye=='generic_a':
            suffix += 'a'
        profile = process_negative_profile(profile)
        save_profile(profile, suffix+'u')
        if align_mid_exp is not None:
            profile = align_midscale_neutral_exposures(profile, reference_channel=align_mid_exp)
        profile = correct_negative_curves_with_gray_ramp(profile, 
                                target_print=target_print, 
                                                        data_trustability=trustability)
        profile = replace_fitted_density_curves(profile)
        profile = adjust_log_exposure(profile)
        save_profile(profile, 'c')
        plot_profile(profile)

plt.show()

