import ctypes
import ipaddress
import logging
import os
import pyverbs
import socket
import struct
import sys
import threading
import time

from pyverbs.device import rdma_get_devices
from pyverbs.enums import *

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s: %(message)s', stream=sys.stderr)

PORT = 12345
BUFFER_SIZE = 60816028


class QpConnectionData(ctypes.BigEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('qp_num', ctypes.c_uint32),
        ('rkey',   ctypes.c_uint32),
        ('addr',   ctypes.c_uint64),
        ('gid',    ctypes.c_ubyte * 16)
    ]


callback = None
keep_polling: bool = True
def poll_cq(cq: pyverbs.cq.CQ, mr: pyverbs.mr.MR) -> None:
    global keep_polling

    while keep_polling:
        wc_num, wc_list = cq.poll(num_entries=1)
        if wc_num > 0:
            for wc in wc_list:
                logging.info(f"CQE: wr_id={wc.wr_id}, status={wc.status}")
                if wc.wr_id == 0xdead:
                    if callback is not None:
                        callback(mr.read(length=BUFFER_SIZE, offset=0))
                    keep_polling = False


def recvn(sock: socket.socket, n: int) -> bytes:
    data = b''

    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            break
        data += chunk
    
    return data


# The SoftRoCE interface name is passed as argument
# The PORT constant is the TCP port where the server is listening
def read_weights(iface: str) -> None:

    server_ip = "3.0.0.1"
    devices_list = pyverbs.device.rdma_get_devices()
    found = False
    for device in devices_list:
        device_name_str = device.name.decode('utf-8')
        if device_name_str == iface:
            found = True
            break
    if not found:
        raise Exception(f"Interface {iface} not found.")

    

    # TCP socket to exchange QP connection parameters with the server
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((server_ip, PORT))
    logging.info(f"RDMA Client: TCP connected to {server_ip}:{PORT}")

    # Open RDMA device context, register local memory
    context = pyverbs.device.Context(name=iface)
    pd = pyverbs.pd.PD(context)
    mr = pyverbs.mr.MR(pd, BUFFER_SIZE, IBV_ACCESS_LOCAL_WRITE)

    # Create Completion Queue and Queue Pair
    cq = pyverbs.cq.CQ(context, 10, None, None, 0)
    qp_init_attr = pyverbs.qp.QPInitAttr(
        qp_type=IBV_QPT_RC,
        scq=cq,
        rcq=cq,
        cap=pyverbs.qp.QPCap(
            max_send_wr=8192,
            max_recv_wr=8192,
            max_send_sge=32,
            max_recv_sge=32
        )
    )
    qp = pyverbs.qp.QP(pd, qp_init_attr)

    # Move QP to INIT state 
    init_attr = pyverbs.qp.QPAttr(qp_state=IBV_QPS_INIT, port_num=1)
    init_attr.pkey_index = 0
    init_attr.qp_access_flags = 0
    qp.modify(init_attr, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS)

    # Exchange QP  data with the server.
    # The server sends first (server.py).
    remote_data = recvn(sock, ctypes.sizeof(QpConnectionData))
    if len(remote_data) != ctypes.sizeof(QpConnectionData):
        raise Exception("RDMA Client: failed to receive connection info from server")
    remote_con = QpConnectionData.from_buffer_copy(remote_data)

    # Build and send our local connection info to the server
    local_gid = context.query_gid(port_num=1, index=1)
    byte_gid = ipaddress.ip_address(local_gid.gid).packed
    local_con_obj = QpConnectionData()
    local_con_obj.qp_num = qp.qp_num
    local_con_obj.rkey = mr.rkey
    local_con_obj.addr = mr.buf
    local_con_obj.gid[:] = byte_gid
    sock.sendall(bytes(local_con_obj))

    # Move QP to RTR (Ready To Receive) using the remote connection info
    rtr_attr = pyverbs.qp.QPAttr(qp_state=IBV_QPS_RTR, path_mtu=IBV_MTU_1024)
    rtr_attr.dest_qp_num = remote_con.qp_num
    rtr_attr.rq_psn = 0
    rtr_attr.max_dest_rd_atomic = 1
    rtr_attr.min_rnr_timer = 31
    remote_gid_str = ipaddress.ip_address(bytes(remote_con.gid)).exploded
    gr = pyverbs.addr.GlobalRoute(dgid=pyverbs.addr.GID(val=remote_gid_str), sgid_index=1)
    rtr_attr.ah_attr = pyverbs.addr.AHAttr(gr=gr, is_global=1, port_num=1)
    qp.modify(rtr_attr, IBV_QP_STATE | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER | IBV_QP_AV)

    # Move QP to RTS (Ready To Send) — connection fully established
    rts_attr = pyverbs.qp.QPAttr(qp_state=IBV_QPS_RTS)
    rts_attr.sq_psn = 0
    rts_attr.timeout = 14
    rts_attr.retry_cnt = 7
    rts_attr.rnr_retry = 7
    rts_attr.max_rd_atomic = 1
    qp.modify(rts_attr, IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC)

    logging.info("RDMA Client: QP connection established, starting CQ polling thread")

    # Start the CQ polling thread — it will call callback() when WR 0xdead completes
    global keep_polling
    keep_polling = True
    cq_thread = threading.Thread(target=poll_cq, args=(cq, mr))
    cq_thread.start()

    # Post an RDMA READ: fetch the full weights from the remote memory into our local MR
    sge = pyverbs.wr.SGE(addr=mr.buf, length=BUFFER_SIZE, lkey=mr.lkey)
    read_wr = pyverbs.wr.SendWR(wr_id=0xdead, sg=[sge], num_sge=1, opcode=IBV_WR_RDMA_READ)
    read_wr.set_wr_rdma(rkey=remote_con.rkey, addr=remote_con.addr)
    qp.post_send(read_wr)
    logging.info("RDMA Client: RDMA READ posted, waiting for completion...")

    # Wait for the READ to complete (poll_cq will stop the thread when WR 0xdead finishes)
    cq_thread.join()
    logging.info("RDMA Client: weights received successfully")

    # finnaly done 
    sock.send(b'\x00')
    sock.close()

