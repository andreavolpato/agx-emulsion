from setuptools import setup

setup(name='agx-emulsion',
      version='0.1.0',
      description='Simulation of analog film photography',
      author='Andrea Volpato',
      author_email='volpedellenevi@gmail.com',
      license='GPLv3',
      packages=['agx_emulsion'],
      package_data={'agx_emulsion': ['data/**/*']},
      zip_safe=False)