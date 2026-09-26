use std::convert::TryFrom;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TlvType {
    Hello = 0x01,
    ControlFocusAt = 0x02,
    VideoFrameKey = 0x03,
    ClockSync = 0x04,
    PairingPayload = 0x05,
    CameraCapabilitiesQuery = 0x06,
    CameraCapabilitiesResponse = 0x07,
    ControlZoomPan = 0x08,
}

impl TryFrom<u16> for TlvType {
    type Error = String;
    fn try_from(val: u16) -> Result<Self, Self::Error> {
        match val {
            0x01 => Ok(TlvType::Hello),
            0x02 => Ok(TlvType::ControlFocusAt),
            0x03 => Ok(TlvType::VideoFrameKey),
            0x04 => Ok(TlvType::ClockSync),
            0x05 => Ok(TlvType::PairingPayload),
            0x06 => Ok(TlvType::CameraCapabilitiesQuery),
            0x07 => Ok(TlvType::CameraCapabilitiesResponse),
            0x08 => Ok(TlvType::ControlZoomPan),
            other => Err(format!("Unknown TLV type: {}", other)),
        }
    }
}

#[derive(Debug, Clone)]
pub struct TlvPacket {
    pub tag: TlvType,
    pub value: Vec<u8>,
}

impl TlvPacket {
    pub fn encode(&self, dest: &mut Vec<u8>) {
        let tag_u16 = self.tag as u16;
        dest.extend_from_slice(&tag_u16.to_be_bytes());
        let len = self.value.len() as u16;
        dest.extend_from_slice(&len.to_be_bytes());
        dest.extend_from_slice(&self.value);
    }

    pub fn decode(src: &[u8]) -> Result<(Self, usize), String> {
        if src.len() < 4 {
            return Err("Insufficient bytes for TLV header".into());
        }
        let tag_u16 = u16::from_be_bytes([src[0], src[1]]);
        let len = u16::from_be_bytes([src[2], src[3]]) as usize;

        if src.len() < 4 + len {
            return Err("Insufficient bytes for TLV value payload".into());
        }

        let tag = TlvType::try_from(tag_u16)?;
        let value = src[4..4 + len].to_vec();

        Ok((TlvPacket { tag, value }, 4 + len))
    }
}