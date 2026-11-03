#pragma once

// TSF declarations missing from MinGW-w64's msctf.h, as in the Windows SDK.

#include <msctf.h>

static const GUID GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT =
    { 0x13a016df, 0x560b, 0x46cd, { 0x94, 0x7a, 0x4c, 0x3a, 0xf1, 0xe0, 0xe3, 0x5d } };
static const GUID GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT =
    { 0x25504fb4, 0x7bab, 0x4bc1, { 0x9c, 0x69, 0xcf, 0x81, 0x89, 0x0f, 0x0e, 0xf5 } };

#define TF_CLIENTID_NULL ((TfClientId)0)
#define TF_IPP_CAPS_IMMERSIVESUPPORT 0x00010000
#define TF_IPP_CAPS_SYSTRAYSUPPORT 0x00020000

#define TF_CLUIE_DOCUMENTMGR 0x00000001
#define TF_CLUIE_COUNT 0x00000002
#define TF_CLUIE_SELECTION 0x00000004
#define TF_CLUIE_STRING 0x00000008
#define TF_CLUIE_PAGEINDEX 0x00000010
#define TF_CLUIE_CURRENTPAGE 0x00000020

static const IID IID_ITfTextInputProcessorEx =
    { 0x6e4e2102, 0xf9cd, 0x433d, { 0xb4, 0x96, 0x30, 0x3c, 0xe0, 0x3a, 0x65, 0x07 } };
MIDL_INTERFACE("6e4e2102-f9cd-433d-b496-303ce03a6507")
ITfTextInputProcessorEx : public ITfTextInputProcessor
{
    virtual HRESULT STDMETHODCALLTYPE ActivateEx(ITfThreadMgr* ptim, TfClientId tid, DWORD dwFlags) = 0;
};

static const IID IID_ITfCandidateListUIElement =
    { 0xea1ea138, 0x19df, 0x11d7, { 0xa6, 0xd2, 0x00, 0x06, 0x5b, 0x84, 0x43, 0x5c } };
MIDL_INTERFACE("ea1ea138-19df-11d7-a6d2-00065b84435c")
ITfCandidateListUIElement : public ITfUIElement
{
    virtual HRESULT STDMETHODCALLTYPE GetUpdatedFlags(DWORD* pdwFlags) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetDocumentMgr(ITfDocumentMgr** ppdim) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetCount(UINT* puCount) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetSelection(UINT* puIndex) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetString(UINT uIndex, BSTR* pstr) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetPageIndex(UINT* pIndex, UINT uSize, UINT* puPageCnt) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetPageIndex(UINT* pIndex, UINT uPageCnt) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetCurrentPage(UINT* puPage) = 0;
};

static const IID IID_ITfCandidateListUIElementBehavior =
    { 0x85fad185, 0x58ce, 0x497a, { 0x94, 0x60, 0x35, 0x53, 0x66, 0xb6, 0x4b, 0x9a } };
MIDL_INTERFACE("85fad185-58ce-497a-9460-355366b64b9a")
ITfCandidateListUIElementBehavior : public ITfCandidateListUIElement
{
    virtual HRESULT STDMETHODCALLTYPE SetSelection(UINT nIndex) = 0;
    virtual HRESULT STDMETHODCALLTYPE Finalize() = 0;
    virtual HRESULT STDMETHODCALLTYPE Abort() = 0;
};
