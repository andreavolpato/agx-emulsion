from enum import Enum

class FilmStocks(Enum):
    # kodak pro
    kodak_ektar_100 = 'kodak_ektar_100_auc'
    kodak_portra_160 = 'kodak_portra_160_auc'
    kodak_portra_400 = 'kodak_portra_400_auc'
    kodak_portra_800 = 'kodak_portra_800_auc'
    kodak_portra_800_push1 = 'kodak_portra_800_push1_auc'
    kodak_portra_800_push2 = 'kodak_portra_800_push2_auc'
    # kodak consumer
    kodak_gold_200 = 'kodak_gold_200_auc'
    kodak_ultramax_400 = 'kodak_ultramax_400_auc'
    # kodak cine
    kodak_vision3_50d = 'kodak_vision3_50d_uc'
    kodak_vision3_250d = 'kodak_vision3_250d_uc'
    kodak_vision3_200t = 'kodak_vision3_200t_uc'
    kodak_vision3_500t = 'kodak_vision3_500t_uc'
    # fuji pro
    fujifilm_pro_400h = 'fujifilm_pro_400h_auc'
    # fuji consumer
    fujifilm_c200 = 'fujifilm_c200_auc'
    fujifilm_xtra_400 = 'fujifilm_xtra_400_auc'

class PrintPapers(Enum):
    # kodak_ultra_endura = 'kodak_ultra_endura_uc' # problematic
    kodak_endura_premier = 'kodak_endura_premier_uc'
    kodak_ektacolor_edge = 'kodak_ektacolor_edge_uc'
    kodak_supra_endura = 'kodak_supra_endura_uc'
    kodak_portra_endura = 'kodak_portra_endura_uc'
    fujifilm_crystal_archive_typeii = 'fujifilm_crystal_archive_typeii_uc'
    kodak_2383 = 'kodak_2383_uc'
    kodak_2393 = 'kodak_2393_uc'

class Illuminants(Enum):
    lamp = 'TH-KG3-L'
    # bulb = 'T'
    # cine = 'K75P'
    # led_rgb = 'LED-RGB1'
