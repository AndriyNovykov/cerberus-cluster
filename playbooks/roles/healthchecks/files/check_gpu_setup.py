#!/usr/bin/env python3

import subprocess
import re
import argparse
import json
from datetime import datetime
from shared_logging import logger
from gpu_bw_test import BandwidthTest
from xid_checker import XidChecker
import os

# Written by the healthchecks role from this host's node_profile entry
# (playbooks/group_vars/all.yml). Holds gpu_count and gpu_type.
NODE_PROFILE_FILE = "/opt/lucid-hpc/healthchecks/node_profile.json"

def get_node_profile():
    with open(NODE_PROFILE_FILE) as f:
        return json.load(f)

def is_user_root():
    # Check if the user is root
    if os.geteuid() != 0:
        logger.debug("User is root")
        return False
    return True

def check_ecc_errors():
    ecc_issues = []
    try:
        # Run the nvidia-smi -q command
        result = subprocess.run(['nvidia-smi', '-q'], stdout=subprocess.PIPE)
    except FileNotFoundError:
        logger.warning("Skipping SRAM/DRAM ECC Test: nvidia-smi command not found")
        return []

    # Decode the output from bytes to string
    output = result.stdout.decode('utf-8')

    # Find the lines containing "SRAM Correctable" and "DRAM Correctable"
    sram_matches = re.findall(r'SRAM Uncorrectable\s+:\s+(\d+)', output)
    if len(sram_matches)==0:
        sram_matches = re.findall(r'SRAM Uncorrectable Parity\s+:\s+(\d+)', output)
    dram_matches = re.findall(r'DRAM Uncorrectable\s+:\s+(\d+)', output)
    gpu_matches = re.findall(r'\nGPU\s+(.*)\n', output)
    vol_sram_line = sram_matches[0::2]
    vol_dram_line = dram_matches[0::2]
    agg_sram_line = sram_matches[1::2]
    agg_dram_line = dram_matches[1::2]

    for i, gpu in enumerate(gpu_matches):
        logger.debug(f"GPU: {gpu}")
        if vol_sram_line[i] != "0":
            logger.debug(f"Volatile SRAM Uncorrectable: {vol_sram_line[i]}")
            ecc_issues.append(f"{gpu_matches[i]} - Volatile SRAM Uncorrectable: {vol_sram_line[i]}")
        if vol_dram_line[i] != "0":
            logger.debug(f"Volatile DRAM Uncorrectable: {vol_dram_line[i]}")
            ecc_issues.append(f"{gpu_matches[i]} - Volatile DRAM Uncorrectable: {vol_dram_line[i]}")
        if agg_sram_line[i] != "0":
            logger.debug(f"Aggregate SRAM Uncorrectable: {agg_sram_line[i]}")
            ecc_issues.append(f"{gpu_matches[i]} - Aggregate SRAM Uncorrectable: {agg_sram_line[i]}")
        if agg_dram_line[i] != "0":
            logger.debug(f"Aggregate DRAM Uncorrectable: {agg_dram_line[i]}")
            ecc_issues.append(f"{gpu_matches[i]} - Aggregate DRAM Uncorrectable: {agg_dram_line[i]}")


    # Check if there are ecc_issues
    if len(ecc_issues) == 0:
        logger.info("GPU ECC Test: Passed")
    else:
        logger.warning("GPU ECC Test: Failed")

    return ecc_issues

def check_row_remap_errors():
    remap_issues = []
    try:
        # Run the nvidia-smi -q command
        result = subprocess.run(['nvidia-smi', '--query-remapped-rows=remapped_rows.pending,remapped_rows.failure,remapped_rows.uncorrectable', '--format=csv,noheader'], stdout=subprocess.PIPE)

        if result.returncode != 0:
            logger.debug(f"Check row remap command exited with error code: {result.returncode}")

    except FileNotFoundError:
        logger.warning("Skipping Row Remap Test: nvidia-smi command not found")
        return []

    # Decode the output from bytes to string
    output = result.stdout.decode('utf-8')
    logger.debug("Output: {}".format(output))
    for i, line in enumerate(output.split('\n')):
        if line == "":
            continue
        tmp_data = line.split(",")
        tmp_data = [x.strip() for x in tmp_data]
        if tmp_data[0] != "0" and tmp_data[0] != "No":
            logger.debug(f"GPU: {i} - Row Remap Pending: {tmp_data[0]}")
            remap_issues.append(f"GPU: {i} Row Remap Pending: {tmp_data[0]}")
        if tmp_data[1] != "0" and tmp_data[0] != "No":
            logger.debug(f"GPU: {i} - Row Remap Failure: {tmp_data[1]}")
            #remap_issues.append(f"GPU: {i} Row Remap Failure: {tmp_data[1]}")
        if tmp_data[2] != "0" and tmp_data[0] != "No":
            logger.debug(f"GPU: {i} - Row Remap Uncorrectable: {tmp_data[2]}")
            if int(tmp_data[2]) > 512:
                remap_issues.append(f"GPU: {i} - Row Remap Uncorrectable >512: {tmp_data[2]}")
            else:
                remap_issues.append(f"GPU: {i} - Row Remap Uncorrectable <512: {tmp_data[2]}")# Check if there are ecc_issues

    if len(remap_issues) == 0:
        logger.info("GPU Remap Test: Passed")
    else:
        logger.warning("GPU Remap Test: Failed")

    return remap_issues

def get_host_serial():
    # Run the shell command
    if not is_user_root():
        result = subprocess.run(['sudo', 'dmidecode', '-s', 'system-serial-number'], stdout=subprocess.PIPE)
    else:
        result = subprocess.run(['dmidecode', '-s', 'system-serial-number'], stdout=subprocess.PIPE)

    # Decode the output from bytes to string
    output = result.stdout.decode('utf-8')

    # Return the serial number
    return output.strip()

def check_bus():
    # Check to see if any devices have fallen of the bus
    command = ['lspci', '-v']
    result = subprocess.run(command, stdout=subprocess.PIPE)
    output = result.stdout.decode('utf-8')
    lines = output.split('\n')
    bus_issues = []
    for line in lines:
        if line.find('(rev ff)') != -1:
            bus_issues.append(line)
    if len(bus_issues) > 0:
        logger.error(f"Devices have fallen off the bus")
    else:
        logger.info("No devices have fallen off the bus")
    if len(bus_issues) == 0:
        logger.info("Bus Check Test: Passed")
        return(bus_issues)
    else:
        logger.warning("Bus Check Test: Failed")
        return(bus_issues)

def check_gpu_count(expected_gpus):
    if expected_gpus == 0:
        logger.info("GPU Count Test: Skipped (node profile expects no GPUs)")
        return []

    # Check the number of GPUs
    try:
        result = subprocess.run(['nvidia-smi', '--list-gpus'], stdout=subprocess.PIPE)
        output = result.stdout.decode('utf-8')
        lines = output.split('\n')
        tmp_results = []
        # remove empty lines
        lines = [line for line in lines if line]
        if len(lines) == expected_gpus:
            logger.info("GPU Count Test: Passed")
        else:
            logger.warning("GPU Count Test: Failed")
            tmp_results.append(f"Expected {expected_gpus} GPUs, found {len(lines)} using nvidia-smi command")
        return tmp_results

    except FileNotFoundError:
        try:
            # Fall back to counting NVIDIA controllers in lspci output
            result = subprocess.run(['lspci'], stdout=subprocess.PIPE)
            output = result.stdout.decode('utf-8')

            tmp_results = []
            for line in output.split('\n'):
                if 'NVIDIA' in line and ('3D controller' in line or 'VGA compatible controller' in line):
                    tmp_results.append(line)
            if len(tmp_results) == expected_gpus:
                logger.info("GPU Count Test: Passed")
                return []
            else:
                logger.warning("GPU Count Test: Failed")
                return [f"Expected {expected_gpus} GPUs, found {len(tmp_results)} in lspci output"]
        except FileNotFoundError:
            logger.warning("Skipping GPU count test: nvidia-smi and lspci commands not found")
            return None

def slurm_reason(message):
    global slurm_drain_reason
    global slurm_error_count
    slurm_drain_reason+=(message+"\n")
    slurm_error_count+=1

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Check Host setup')
    parser.add_argument("-l", "--log-level", choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], default="INFO", help="Set the logging level default: INFO")
    parser.add_argument('--bw-test', dest='bw_test', action='store_true', default=False, help='Run GPU bandwidth test (default: False)')
    parser.add_argument('--bw-test-exe', dest='bw_test_exe', help='Location to cuda-sampels bandwidthTest')
    parser.add_argument('-a','--all', dest='run_all', action='store_true', default=False, help='Run all checks (default: False)')
    parser.add_argument('-slurm','--slurm', dest='slurm', action='store_true', default=False, help='Add a Slurm message')
    args = parser.parse_args()

    logger.setLevel(args.log_level)

    datetime_str = datetime.now().strftime('%Y-%m-%d-%H%M%S')
    logger.info(f"Started GPU host setup check at: {datetime_str}")

    try:
        node_profile = get_node_profile()
        expected_gpus = int(node_profile.get("gpu_count", 0))
    except Exception as e:
        logger.warning(f"Failed to read node profile {NODE_PROFILE_FILE} with error: {e}")
        node_profile = {}
        expected_gpus = 0

    # Check for ECC errors
    try:
        ecc_issues = check_ecc_errors()
    except Exception as e:
        logger.warning(f"Failed to check ECC errors with error: {e}")
        ecc_issues = []

    # Check for row remap errors
    try:
        remap_results = check_row_remap_errors()
    except Exception as e:
        logger.warning(f"Failed to check row remap errors with error: {e}")
        remap_results = []

    # Check for GPU Xid errors
    try:
        xc = XidChecker()
        xid_results = xc.check_gpu_xid()
    except Exception as e:
        logger.warning(f"Failed to check GPU Xid errors with error: {e}")
        xid_results = {"status": "None", "results": {}}

    # Check GPU bandwidth
    bwt_results = None
    try:
        if args.bw_test == True or args.run_all == True:
            if args.bw_test_exe:
                bwt = BandwidthTest(bw_test_exe=args.bw_test_exe)
            else:
                bwt = BandwidthTest()
            bwt.measure_gpu_bw()
            bwt_results = bwt.validate_results()
    except Exception as e:
        logger.warning(f"Failed to check GPU bandwidth with error: {e}")
        bwt_results = None

    # Check the bus
    try:
        bus_results = check_bus()
    except Exception as e:
        logger.warning(f"Failed to check the bus with error: {e}")
        bus_results = None

    # Check the number of GPUs
    try:
        gpu_results = check_gpu_count(expected_gpus)
    except Exception as e:
        logger.warning(f"Failed to check the number of GPUs with error: {e}")
        gpu_results = None

    # Summarize the results
    try:
        host_serial = get_host_serial()
    except Exception as e:
        logger.warning(f"Failed to get host serial number with error: {e}")
        host_serial = "Unknown"

    slurm_drain_reason = ""
    slurm_error_count = 0

    logger.info(f"--------- Summary of Host setup check for {host_serial} ---------")
    if len(ecc_issues) > 0:
        ecc_error=False
        for issue in ecc_issues:
            if "Skipped" in issue:
                logger.warning(f"{host_serial} - {issue}")
            else:
                if "Aggregate" in issue:
                    logger.warning(f"{host_serial} - ECC issues: {issue}")
                else:
                    logger.error(f"{host_serial} - ECC issues: {issue}")
                    ecc_error=True
        if ecc_error:
            slurm_reason("ECC Error")
    if len(remap_results) > 0:
        remap_error=False
        for issue in remap_results:
            if "<512" in issue:
                logger.warning(f"{host_serial} - {issue}")
            else:
                logger.error(f"{host_serial} - {issue}")
                remap_error=True
        if remap_error:
            slurm_reason("Remap Error")
    if xid_results["status"] == "Failed":
        for xid in xid_results["results"]:
            for pci in xid_results["results"][xid]["results"]:
                logger.error(f"{host_serial} - GPU Xid {xid} device: {pci}, {xid_results['results'][xid]['description']}")
                slurm_reason("XID Error")
    if bwt_results != None:
        if bwt_results["status"] == "Failed":
            for issue in bwt_results["issues"]:
                logger.error(f"{host_serial} - GPU bandwidth issues: {issue}")
                slurm_reason("GPU Bwt Error")
    if bus_results:
        logger.error(f"{host_serial} - Bus issues: {bus_results}")
        slurm_reason("GPU Bus Error")
    if gpu_results:
        logger.error(f"{host_serial} - Missing GPU(s): {gpu_results}")
        slurm_reason("Missing GPU Error")

    datetime_str = datetime.now().strftime('%Y-%m-%d-%H%M%S')
    logger.info(f"Finished GPU host setup check at: {datetime_str}")

    if slurm_error_count > 0 and args.slurm:
        print("Healthcheck:: "+slurm_drain_reason[:-1])
